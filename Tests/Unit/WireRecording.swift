import Foundation
import Network
import XCTest
@testable import GaussiansCapture

// A wire recording is a directory: script.txt, the line `wire-script 1` then one event per line in the
// order the recorder saw them (`<conn> phone|pc <message>`, or `<conn> end close|cut|silent phone|pc`),
// and per connection conn-<n>.phone.bin and conn-<n>.pc.bin, every byte each side sent on it. A message
// cut short is not an event; its bytes up to the cut end its side's file, and `end cut <side>` follows.
final class WireRecorder {
    private let lock = NSLock()
    private var lines = ["wire-script 1"]
    private var files: [String: Data] = [:]
    private var connections = 0

    static func file(_ conn: Int, _ side: String) -> String {
        "conn-\(conn).\(side).bin"
    }

    // A new connection's number, from 1.
    func open() -> Int {
        lock.lock()
        defer { lock.unlock() }
        connections += 1
        files[WireRecorder.file(connections, "phone")] = Data()
        files[WireRecorder.file(connections, "pc")] = Data()
        return connections
    }

    func message(_ conn: Int, _ side: String, _ name: String, _ raw: Data) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("\(conn) \(side) \(name)")
        files[WireRecorder.file(conn, side), default: Data()].append(raw)
    }

    func partial(_ conn: Int, _ side: String, _ raw: Data) {
        lock.lock()
        defer { lock.unlock() }
        files[WireRecorder.file(conn, side), default: Data()].append(raw)
    }

    func end(_ conn: Int, _ how: String, _ side: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("\(conn) end \(how) \(side)")
    }

    var script: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func bytes(_ conn: Int, _ side: String) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return files[WireRecorder.file(conn, side)] ?? Data()
    }

    func write(to dir: URL) throws {
        lock.lock()
        let lines = self.lines
        let files = self.files
        lock.unlock()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("script.txt"))
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent(name))
        }
    }
}

enum WireScript {
    // nil when every line is well formed, else the first bad line.
    static func problem(_ lines: [String]) -> String? {
        guard lines.first == "wire-script 1" else { return "the first line is not 'wire-script 1'" }
        let names = Set(LinkMessageType.allCases.map { $0.rawValue })
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let conn = Int(parts.first ?? ""), conn >= 1, String(conn) == parts[0] else { return line }
            if parts.count == 3, parts[1] == "phone" || parts[1] == "pc", names.contains(parts[2]) { continue }
            if parts.count == 4, parts[1] == "end", ["close", "cut", "silent"].contains(parts[2]),
               parts[3] == "phone" || parts[3] == "pc" { continue }
            return line
        }
        return nil
    }

    static func read(_ dir: URL) throws -> [String] {
        let text = try String(contentsOf: dir.appendingPathComponent("script.txt"), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

// A PC on 127.0.0.1 that follows the protocol's rules: it pairs by code or token, accepts the take
// from the record after the last it holds, refuses a record out of order by ending the link, and
// answers pings. It can cut one connection partway through one record, as a dropped link does. It
// records both sides of every connection, and writes the take it receives as a directory.
final class LoopbackPC {
    let code: String
    let token: String
    let pcName: String
    let cut: (connection: Int, index: Int)?
    let received: URL
    let recorder = WireRecorder()
    let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.tests.pc")

    var onTakeStop: (() -> Void)?
    var onConnectionEnded: ((Int) -> Void)?

    // Queue only.
    private var listener: NWListener?
    private var sessions: [Int: Session] = [:]
    private(set) var captureId: String?
    private(set) var have = -1
    private(set) var recordsByConnection: [Int: [Int]] = [:]
    private(set) var takeStops: [String] = []

    private final class Session {
        let number: Int
        let connection: NWConnection
        var inbox: [UInt8] = []
        var ended = false

        init(_ number: Int, _ connection: NWConnection) {
            self.number = number
            self.connection = connection
        }
    }

    init(code: String, token: String, pcName: String, cut: (connection: Int, index: Int)?, received: URL) {
        self.code = code
        self.token = token
        self.pcName = pcName
        self.cut = cut
        self.received = received
    }

    // The port it listens on.
    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "LoopbackPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "the listener did not start"])
        }
        self.listener = listener
        return port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for s in sessions.values where !s.ended {
                s.ended = true
                s.connection.cancel()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let s = Session(recorder.open(), connection)
        sessions[s.number] = s
        recordsByConnection[s.number] = []
        connection.start(queue: queue)
        receive(s)
    }

    private func receive(_ s: Session) {
        s.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self, !s.ended else { return }
            if let data = data, !data.isEmpty {
                s.inbox.append(contentsOf: data)
                self.process(s)
            }
            if s.ended { return }
            if isComplete || error != nil {
                self.finish(s, "close", "phone")
                return
            }
            self.receive(s)
        }
    }

    private func process(_ s: Session) {
        while !s.ended {
            switch LinkFraming.decode(s.inbox, streamEnded: false) {
            case .failure:
                finish(s, "close", "pc")
                return
            case .success(.incomplete):
                return
            case .success(.message(let m, let consumed)):
                if m.type == .record, let cut = cut, cut.connection == s.number, recordIndex(m) == cut.index {
                    let keep = consumed - m.payload.count + m.payload.count / 2
                    recorder.partial(s.number, "phone", Data(s.inbox[0..<keep]))
                    finish(s, "cut", "phone")
                    return
                }
                recorder.message(s.number, "phone", m.type.rawValue, Data(s.inbox[0..<consumed]))
                s.inbox.removeFirst(consumed)
                handle(m, s)
            }
        }
    }

    private func recordIndex(_ m: LinkMessage) -> Int? {
        let prefix = [UInt8](m.payload.prefix(LinkFraming.headerMaxBytes))
        guard case .success(let h) = LinkFraming.parseHeader(prefix) else { return nil }
        return h.value("frame.index").flatMap { Int($0) }
    }

    private func handle(_ m: LinkMessage, _ s: Session) {
        switch m.type {
        case .hello:
            if m.value("pair.code") == code {
                reply(LinkMessage(.welcome, [("pc.name", pcName), ("pair.token", token)]), s)
            } else if m.value("pair.token") == token {
                reply(LinkMessage(.welcome, [("pc.name", pcName)]), s)
            } else {
                reply(LinkMessage(.refused, [("reason", "code")]), s)
                finish(s, "close", "pc")
            }
        case .takeStart:
            guard let id = m.value("capture.id"), captureId == nil || captureId == id else {
                finish(s, "close", "pc")
                return
            }
            if captureId == nil {
                captureId = id
                try? FileManager.default.createDirectory(at: received.appendingPathComponent("records", isDirectory: true),
                                                         withIntermediateDirectories: true)
                try? m.payload.write(to: received.appendingPathComponent("manifest.txt"))
            }
            reply(LinkMessage(.takeAccepted, [("have", String(have))]), s)
        case .record:
            guard let index = recordIndex(m), index == have + 1, write(m.payload, index) else {
                finish(s, "close", "pc")
                return
            }
            have = index
            recordsByConnection[s.number, default: []].append(index)
        case .takeStop:
            takeStops.append(m.value("last") ?? "")
            onTakeStop?()
        case .ping:
            reply(LinkMessage(.pong), s)
        default:
            break
        }
    }

    private func write(_ payload: Data, _ index: Int) -> Bool {
        writeStreamRecord(payload, index, into: received)
    }

    private func reply(_ m: LinkMessage, _ s: Session) {
        guard let raw = LinkFraming.encode(m) else { return }
        recorder.message(s.number, "pc", m.type.rawValue, raw)
        s.connection.send(content: raw, completion: .contentProcessed { _ in })
    }

    private func finish(_ s: Session, _ how: String, _ side: String) {
        guard !s.ended else { return }
        s.ended = true
        recorder.end(s.number, how, side)
        s.connection.cancel()
        onConnectionEnded?(s.number)
    }
}

// The files of two take directories that differ: missing on one side, or not byte-identical.
func takeDifferences(_ a: URL, _ b: URL) -> [String] {
    let fm = FileManager.default
    func files(_ root: URL) -> Set<String> {
        var out = Set<String>()
        if fm.fileExists(atPath: root.appendingPathComponent("manifest.txt").path) { out.insert("manifest.txt") }
        for name in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("records").path)) ?? [] {
            out.insert("records/" + name)
        }
        return out
    }
    let left = files(a)
    let right = files(b)
    var out = left.symmetricDifference(right).sorted().map { "only on one side: " + $0 }
    for name in left.intersection(right).sorted() {
        let x = try? Data(contentsOf: a.appendingPathComponent(name))
        let y = try? Data(contentsOf: b.appendingPathComponent(name))
        if x == nil || x != y { out.append("differs: " + name) }
    }
    return out
}

// As the PC stores a record: the header file, then each blob under its derived name.
func writeStreamRecord(_ payload: Data, _ index: Int, into take: URL) -> Bool {
    let bytes = [UInt8](payload)
    guard case .success(let h) = LinkFraming.parseHeader(Array(bytes.prefix(LinkFraming.headerMaxBytes))) else { return false }
    let records = take.appendingPathComponent("records", isDirectory: true)
    try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let stem = TakeStorage.recordStem(index)
    var parts: [(String, Int)] = [(".txt", h.byteCount)]
    let color = h.value("color.encoding") == "png" ? ".color.png" : ".color.jpg"
    for (suffix, key) in [(color, "color.bytes"), (".depth.f32", "depth.bytes"), (".conf.u8", "confidence.bytes")] {
        if let n = h.value(key).flatMap({ Int($0) }) { parts.append((suffix, n)) }
    }
    var offset = 0
    for (suffix, n) in parts {
        guard offset + n <= bytes.count else { return false }
        do {
            try Data(bytes[offset..<(offset + n)]).write(to: records.appendingPathComponent(stem + suffix))
        } catch {
            return false
        }
        offset += n
    }
    return offset == bytes.count
}

extension XCTestCase {
    func waitUntil(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for " + what)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
