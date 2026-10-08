import Foundation
import Security

// Where the link dials: an address, or a Bonjour instance of the PC's service.
enum LinkTarget: Equatable {
    case hostPort(String, UInt16)
    case service(String)

    static let serviceType = "_gaussians._tcp"

    var text: String {
        switch self {
        case .hostPort(let host, let port): return host + ":" + String(port)
        case .service(let name): return name
        }
    }
}

enum PhoneName {
    static let maxLength = 32
    static let fallback = "iPhone"

    // Printable ASCII, the only names the header grammar and the PC's store accept: transliterated to
    // Latin, diacritics stripped, anything else outside 0x20-0x7E made '-', cut to 32 characters.
    static func fold(_ name: String) -> String {
        var s = name.applyingTransform(.toLatin, reverse: false) ?? name
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        var out = ""
        var count = 0
        for u in s.unicodeScalars {
            if count == maxLength { break }
            if u.value >= 0x20 && u.value <= 0x7E {
                out.unicodeScalars.append(u)
            } else {
                out += "-"
            }
            count += 1
        }
        return out.isEmpty ? fallback : out
    }
}

enum LinkAddress {
    // "host" or "host:port", split at the last colon; the port 7420 when none is given.
    static func parse(_ text: String) -> (host: String, port: UInt16)? {
        guard let colon = text.lastIndex(of: ":") else {
            return text.isEmpty ? nil : (text, LinkFraming.defaultPort)
        }
        guard colon != text.startIndex else { return nil }
        let portText = String(text[text.index(after: colon)...])
        guard let port = LinkFraming.parseUnsigned(portText), port >= 1, port <= 65535 else { return nil }
        return (String(text[text.startIndex..<colon]), UInt16(port))
    }
}

struct PairingTarget: Equatable {
    let host: String
    let port: UInt16
    let code: String
}

enum PairingURL {
    static let scheme = "gaussians"

    static func isCode(_ s: String) -> Bool {
        s.utf8.count == 6 && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    // gaussians://pair?host=<host>&port=<port>&code=<six digits>; the port 7420 when it is absent.
    static func parse(_ text: String) -> PairingTarget? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == "pair" else { return nil }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let host = item("host"), !host.isEmpty,
              let code = item("code"), isCode(code) else { return nil }
        var port = LinkFraming.defaultPort
        if let portText = item("port") {
            guard let p = LinkFraming.parseUnsigned(portText), p >= 1, p <= 65535 else { return nil }
            port = UInt16(p)
        }
        return PairingTarget(host: host, port: port, code: code)
    }
}

// The paired PC: its token in the Keychain, one generic-password item that neither syncs nor restores
// onto another device; its name and how to reach it in UserDefaults. One PC at a time.
final class PairingStore {
    let service: String
    private let defaults: UserDefaults
    private let account = "token"

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.vkorytsko.gaussianscapture") + ".pc",
         defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // errSecSuccess when stored.
    @discardableResult
    func setToken(_ token: String) -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    var pcName: String? {
        get { defaults.string(forKey: service + ".name") }
        set { defaults.set(newValue, forKey: service + ".name") }
    }

    var target: LinkTarget? {
        get {
            if let name = defaults.string(forKey: service + ".instance") { return .service(name) }
            if let address = defaults.string(forKey: service + ".address"), let parsed = LinkAddress.parse(address) {
                return .hostPort(parsed.host, parsed.port)
            }
            return nil
        }
        set {
            defaults.removeObject(forKey: service + ".instance")
            defaults.removeObject(forKey: service + ".address")
            switch newValue {
            case .service(let name)?: defaults.set(name, forKey: service + ".instance")
            case .hostPort?: defaults.set(newValue?.text, forKey: service + ".address")
            case nil: break
            }
        }
    }

    // Forget: the token, the PC's name and how to reach it.
    func forget() {
        deleteToken()
        pcName = nil
        target = nil
    }
}
