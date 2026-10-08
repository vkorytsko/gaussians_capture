import Foundation

// The link's messages: a bundle-style text header (the magic line, link.version, link.message,
// link.bytes, then the message's own keys), then link.bytes payload bytes. Pure functions over bytes.

enum LinkMessageType: String, CaseIterable {
    case hello
    case welcome
    case refused
    case takeStart = "take.start"
    case takeAccepted = "take.accepted"
    case takeRefused = "take.refused"
    case record
    case takeStop = "take.stop"
    case progress
    case thumbnail
    case ping
    case pong
}

struct HeaderLine: Equatable {
    let key: String
    let value: String
}

struct LinkMessage: Equatable {
    var type: LinkMessageType
    var fields: [HeaderLine] = []
    var payload = Data()

    init(_ type: LinkMessageType, _ fields: [(String, String)] = [], payload: Data = Data()) {
        self.type = type
        self.fields = fields.map { HeaderLine(key: $0.0, value: $0.1) }
        self.payload = payload
    }

    func value(_ key: String) -> String? {
        fields.first(where: { $0.key == key })?.value
    }
}

enum LinkErrorKind: Equatable {
    case malformed, version, tooLarge, cutOff
}

struct LinkError: Error, Equatable {
    let kind: LinkErrorKind
    let text: String
}

enum LinkDecoded: Equatable {
    case incomplete
    case message(LinkMessage, consumed: Int)
}

// A parsed header: its key=value lines in order, comments left out, and its length including the
// empty line that ends it.
struct ParsedHeader {
    let lines: [HeaderLine]
    let byteCount: Int

    func value(_ key: String) -> String? {
        lines.first(where: { $0.key == key })?.value
    }
}

enum LinkFraming {
    static let version = 1
    static let defaultPort: UInt16 = 7420
    static let maxPayload = 64 << 20
    static let headerMaxBytes = 64 * 1024
    static let magic = "# gd-capture-bundle"

    private static let lf: UInt8 = 0x0A

    static func isHeaderByte(_ b: UInt8) -> Bool {
        b == 0x09 || b == 0x0A || (b >= 0x20 && b <= 0x7E)
    }

    static func isKeyByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2E
    }

    // Decimal digits only, as the reference reader accepts.
    static func parseUnsigned(_ s: String) -> UInt64? {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return UInt64(s)
    }

    // nil for a key outside [a-z0-9_.], a key under link., or a value holding a byte a header cannot.
    static func encode(_ m: LinkMessage, version: Int = LinkFraming.version) -> Data? {
        var text = magic + "\n"
        text += "link.version=" + String(version) + "\n"
        text += "link.message=" + m.type.rawValue + "\n"
        text += "link.bytes=" + String(m.payload.count) + "\n"
        for f in m.fields {
            guard !f.key.isEmpty, !f.key.hasPrefix("link."),
                  f.key.utf8.allSatisfy(isKeyByte),
                  f.value.utf8.allSatisfy({ isHeaderByte($0) && $0 != lf }) else { return nil }
            text += f.key + "=" + f.value + "\n"
        }
        text += "\n"
        var out = Data(text.utf8)
        guard out.count <= headerMaxBytes else { return nil }
        out.append(m.payload)
        return out
    }

    // One past the empty line ending the header at the front of `bytes`, or nil when it is not there.
    static func headerEnd(_ bytes: [UInt8]) -> Int? {
        let limit = min(bytes.count, headerMaxBytes)
        var i = 1
        while i < limit {
            if bytes[i] == lf && bytes[i - 1] == lf { return i + 1 }
            i += 1
        }
        return nil
    }

    static func parseHeader(_ bytes: [UInt8]) -> Result<ParsedHeader, LinkError> {
        guard let end = headerEnd(bytes) else {
            return .failure(LinkError(kind: .malformed, text: "the header has no empty line within \(headerMaxBytes) bytes"))
        }
        for i in 0..<end where !isHeaderByte(bytes[i]) {
            return .failure(LinkError(kind: .malformed, text: "header byte \(bytes[i]) at offset \(i) is outside its ASCII set"))
        }
        // Every line but the empty one that ends the header.
        let text = String(decoding: bytes[0..<(end - 2)], as: UTF8.self)
        var lines: [HeaderLine] = []
        var lineNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let line = String(raw)
            if lineNo == 1 {
                guard line == magic else {
                    return .failure(LinkError(kind: .malformed, text: "first line is not the magic '\(magic)'"))
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else {
                return .failure(LinkError(kind: .malformed, text: "line \(lineNo) is neither key=value nor a comment"))
            }
            let key = String(line[line.startIndex..<eq])
            guard key.utf8.allSatisfy(isKeyByte) else {
                return .failure(LinkError(kind: .malformed, text: "line \(lineNo): key '\(key)' is outside [a-z0-9_.]"))
            }
            guard !lines.contains(where: { $0.key == key }) else {
                return .failure(LinkError(kind: .malformed, text: "line \(lineNo): duplicate key '\(key)'"))
            }
            lines.append(HeaderLine(key: key, value: String(line[line.index(after: eq)...])))
        }
        return .success(ParsedHeader(lines: lines, byteCount: end))
    }

    // The message at the front of `bytes`: .incomplete while it has not all arrived and the stream goes
    // on. With `streamEnded`, a partial message is cutOff. The version is judged before any other key.
    static func decode(_ bytes: [UInt8], maxPayload: Int = LinkFraming.maxPayload, streamEnded: Bool,
                       version: Int = LinkFraming.version) -> Result<LinkDecoded, LinkError> {
        if headerEnd(bytes) == nil && bytes.count < headerMaxBytes {
            if !streamEnded || bytes.isEmpty { return .success(.incomplete) }
            return .failure(LinkError(kind: .cutOff, text: "the link ended \(bytes.count) bytes into a message header"))
        }
        let header: ParsedHeader
        switch parseHeader(bytes) {
        case .failure(let e): return .failure(e)
        case .success(let h): header = h
        }
        guard let versionText = header.value("link.version"), let v = parseUnsigned(versionText) else {
            return .failure(LinkError(kind: .malformed, text: "the header has no link.version"))
        }
        guard v == UInt64(version) else {
            return .failure(LinkError(kind: .version,
                                      text: "link.version=\(versionText) is not this end's link.version=\(version)"))
        }
        guard let name = header.value("link.message") else {
            return .failure(LinkError(kind: .malformed, text: "the header has no link.message"))
        }
        guard let type = LinkMessageType(rawValue: name) else {
            return .failure(LinkError(kind: .malformed, text: "link.message=\(name) is no message this end knows"))
        }
        guard let declaredText = header.value("link.bytes"), let declared = parseUnsigned(declaredText) else {
            return .failure(LinkError(kind: .malformed, text: "the header has no link.bytes"))
        }
        guard declared <= UInt64(maxPayload) else {
            return .failure(LinkError(kind: .tooLarge, text: "\(name) declares \(declared) payload bytes, over \(maxPayload)"))
        }
        let payloadBytes = Int(declared)
        let present = bytes.count - header.byteCount
        if present < payloadBytes {
            if !streamEnded { return .success(.incomplete) }
            return .failure(LinkError(kind: .cutOff,
                                      text: "\(name) declares \(payloadBytes) payload bytes and the link ended after \(present)"))
        }
        var m = LinkMessage(type)
        m.fields = header.lines.filter { !$0.key.hasPrefix("link.") }
        m.payload = Data(bytes[header.byteCount..<(header.byteCount + payloadBytes)])
        return .success(.message(m, consumed: header.byteCount + payloadBytes))
    }
}
