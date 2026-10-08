import Security
import XCTest
@testable import GaussiansCapture

final class LinkPairingTests: XCTestCase {
    func testPhoneNamesFoldToPrintableASCII() {
        let cases: [(String, String)] = [
            ("iPhone", "iPhone"),
            ("Zo\u{00EB}'s iPhone", "Zoe's iPhone"),
            ("\u{0412}\u{043B}\u{0430}\u{0434}", "Vlad"),
            ("a\tb", "a-b"),
            ("Vlad \u{1F4F1}", "Vlad -"),
            ("", "iPhone"),
            (String(repeating: "x", count: 40), String(repeating: "x", count: 32)),
        ]
        for (name, folded) in cases {
            XCTAssertEqual(PhoneName.fold(name), folded, name)
        }
        for (name, _) in cases {
            let f = PhoneName.fold(name)
            XCTAssertLessThanOrEqual(f.utf8.count, PhoneName.maxLength)
            XCTAssertTrue(f.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }, f)
        }
    }

    // The failing case: the name unfolded is refused by the header grammar.
    func testAnUnfoldedNameCannotBeSent() {
        let name = "Zo\u{00EB}'s iPhone"
        XCTAssertNil(LinkFraming.encode(LinkMessage(.hello, [("phone.name", name)])))
        XCTAssertNotNil(LinkFraming.encode(LinkMessage(.hello, [("phone.name", PhoneName.fold(name))])))
    }

    func testAddresses() {
        for (text, host, port) in [("192.168.1.20", "192.168.1.20", UInt16(7420)),
                                   ("192.168.1.20:7421", "192.168.1.20", UInt16(7421)),
                                   ("pc.local:80", "pc.local", UInt16(80))] {
            let parsed = LinkAddress.parse(text)
            XCTAssertEqual(parsed?.host, host, text)
            XCTAssertEqual(parsed?.port, port, text)
        }
        // The failing cases, each wrong in one way.
        for bad in ["", ":7420", "host:", "host:0", "host:65536", "host:12a", "host:+5", "host:-1"] {
            XCTAssertNil(LinkAddress.parse(bad), bad)
        }
    }

    func testPairingURLs() {
        XCTAssertEqual(PairingURL.parse("gaussians://pair?host=192.168.1.20&port=7420&code=246813"),
                       PairingTarget(host: "192.168.1.20", port: 7420, code: "246813"))
        XCTAssertEqual(PairingURL.parse("gaussians://pair?host=10.0.0.5&code=000001"),
                       PairingTarget(host: "10.0.0.5", port: 7420, code: "000001"))
        // The failing cases: a five-digit code, and the rest each wrong in one way.
        for bad in ["gaussians://pair?host=192.168.1.20&port=7420&code=24681",
                    "gaussians://pair?host=192.168.1.20&port=7420&code=2468131",
                    "gaussians://pair?host=192.168.1.20&port=7420&code=24681x",
                    "gaussians://pair?port=7420&code=246813",
                    "gaussians://pair?host=192.168.1.20&port=0&code=246813",
                    "gaussians://pair?host=192.168.1.20&port=70000&code=246813",
                    "gaussians://other?host=192.168.1.20&port=7420&code=246813",
                    "https://pair?host=192.168.1.20&port=7420&code=246813"] {
            XCTAssertNil(PairingURL.parse(bad), bad)
        }
    }

    func testTheKeychainHoldsTheTokenUntilForget() {
        let suite = "gc-tests-pairing"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PairingStore(service: "com.vkorytsko.gaussianscapture.pc.test", defaults: defaults)
        store.forget()
        XCTAssertNil(store.token())

        let status = store.setToken(LinkProtocolTests.token)
        XCTAssertEqual(status, errSecSuccess, "SecItemAdd returned \(status)")
        XCTAssertEqual(store.token(), LinkProtocolTests.token)
        // The failing case of the lookup: another service holds nothing.
        XCTAssertNil(PairingStore(service: "com.vkorytsko.gaussianscapture.pc.other", defaults: defaults).token())

        store.pcName = "TEST-PC"
        store.target = .hostPort("127.0.0.1", 7421)
        XCTAssertEqual(store.pcName, "TEST-PC")
        XCTAssertEqual(store.target, .hostPort("127.0.0.1", 7421))
        store.target = .service("TEST-PC")
        XCTAssertEqual(store.target, .service("TEST-PC"))

        store.forget()
        XCTAssertNil(store.token())
        XCTAssertNil(store.pcName)
        XCTAssertNil(store.target)
        defaults.removePersistentDomain(forName: suite)
    }
}
