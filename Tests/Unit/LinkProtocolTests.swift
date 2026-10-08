import XCTest
@testable import GaussiansCapture

// link-messages.bin holds one of each message, as the reference encoder writes them for the values below.
final class LinkProtocolTests: XCTestCase {
    static let token = "00112233445566778899aabbccddeeff"

    static func manifest() -> Data {
        Data("# gd-capture-bundle\nbundle.version=1.0\nrecord.kind=manifest\n\n".utf8)
    }

    static func recordPayload() -> Data {
        Data((0..<100).map { UInt8(truncatingIfNeeded: $0 % 3 == 0 ? 0x0A : $0 * 7) })
    }

    static func thumbnailPayload() -> Data {
        Data((0..<32).map { UInt8(0xFF - $0) })
    }

    static func expected() -> [LinkMessage] {
        let token = LinkProtocolTests.token
        return [
            LinkMessage(.hello, [("phone.name", "iPhone"), ("app.version", "0.2.0+1"), ("pair.code", "246813")]),
            LinkMessage(.hello, [("phone.name", "iPhone"), ("app.version", "0.2.0+1"), ("pair.token", token)]),
            LinkMessage(.welcome, [("pc.name", "TEST-PC"), ("pair.token", token)]),
            LinkMessage(.welcome, [("pc.name", "TEST-PC")]),
            LinkMessage(.refused, [("reason", "code")]),
            LinkMessage(.refused, [("reason", "pairing closed")]),
            LinkMessage(.refused, [("reason", "version"), ("detail", "link.version=2 is not this end's link.version=1")]),
            LinkMessage(.takeStart, [("capture.id", "6f9619ff-8b86-d011-b42d-00c04fc964ff")], payload: manifest()),
            LinkMessage(.takeAccepted, [("have", "-1")]),
            LinkMessage(.takeAccepted, [("have", "1")]),
            LinkMessage(.takeRefused, [("reason", "busy"), ("detail", "a session is running")]),
            LinkMessage(.record, [("age_ms", "37")], payload: recordPayload()),
            LinkMessage(.takeStop, [("last", "2")]),
            LinkMessage(.progress, [("iteration", "1200"), ("splats", "45678"), ("frames", "3"), ("psnr_db", "27.125"),
                                    ("loss", "0.031250"), ("behind_s", "0.412")]),
            LinkMessage(.thumbnail, [("iteration", "1200")], payload: thumbnailPayload()),
            LinkMessage(.ping),
            LinkMessage(.pong),
        ]
    }

    func golden() throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: LinkProtocolTests.self).url(forResource: "link-messages", withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }

    func testTheReferenceMessagesDecodeAndReencodeByteForByte() throws {
        var bytes = try golden()
        let expected = LinkProtocolTests.expected()
        var decoded: [LinkMessage] = []
        while !bytes.isEmpty {
            guard case .success(.message(let m, let consumed)) = LinkFraming.decode(bytes, streamEnded: true) else {
                XCTFail("message \(decoded.count) did not decode")
                return
            }
            XCTAssertEqual(LinkFraming.encode(m).map { [UInt8]($0) }, Array(bytes[0..<consumed]), "message \(decoded.count)")
            decoded.append(m)
            bytes.removeFirst(consumed)
        }
        XCTAssertEqual(decoded, expected)
        for m in expected {
            XCTAssertNotNil(LinkFraming.encode(m))
        }
        XCTAssertEqual(decoded[13].value("behind_s"), "0.412")
        XCTAssertEqual(decoded[14].payload, LinkProtocolTests.thumbnailPayload())
    }

    // A message waits until all of it has arrived. The failing case: the same prefix with the stream
    // ended is cut off.
    func testAMessageArrivingInPiecesIsWaitedFor() throws {
        let whole = [UInt8](try XCTUnwrap(LinkFraming.encode(LinkProtocolTests.expected()[7])))
        for n in 0..<whole.count {
            let prefix = Array(whole[0..<n])
            XCTAssertEqual(LinkFraming.decode(prefix, streamEnded: false), .success(.incomplete), "prefix \(n)")
            if n > 0 {
                guard case .failure(let e) = LinkFraming.decode(prefix, streamEnded: true) else {
                    XCTFail("prefix \(n) of an ended stream decoded")
                    return
                }
                XCTAssertEqual(e.kind, .cutOff)
            }
        }
        XCTAssertEqual(LinkFraming.decode(whole, streamEnded: false),
                       .success(.message(LinkProtocolTests.expected()[7], consumed: whole.count)))
    }

    func testACutPayloadIsWaitedForThenRefusedAtTheClose() throws {
        let whole = [UInt8](try XCTUnwrap(LinkFraming.encode(LinkProtocolTests.expected()[11])))
        let cut = Array(whole[0..<(whole.count - 10)])
        XCTAssertEqual(LinkFraming.decode(cut, streamEnded: false), .success(.incomplete))
        XCTAssertEqual(LinkFraming.decode(cut, streamEnded: true),
                       .failure(LinkError(kind: .cutOff, text: "record declares 100 payload bytes and the link ended after 90")))
    }

    // The failing case is version 2; version 1 is the same message accepted.
    func testAnotherVersionIsRefusedNamingBoth() throws {
        let two = [UInt8](try XCTUnwrap(LinkFraming.encode(LinkMessage(.ping), version: 2)))
        XCTAssertEqual(LinkFraming.decode(two, streamEnded: false),
                       .failure(LinkError(kind: .version, text: "link.version=2 is not this end's link.version=1")))
        let one = [UInt8](try XCTUnwrap(LinkFraming.encode(LinkMessage(.ping), version: 1)))
        XCTAssertEqual(LinkFraming.decode(one, streamEnded: false), .success(.message(LinkMessage(.ping), consumed: one.count)))
    }

    func testEncodingRefusesWhatAHeaderCannotCarry() {
        XCTAssertNil(LinkFraming.encode(LinkMessage(.hello, [("link.bytes", "1")])))
        XCTAssertNil(LinkFraming.encode(LinkMessage(.hello, [("Phone.Name", "x")])))
        XCTAssertNil(LinkFraming.encode(LinkMessage(.hello, [("phone.name", "a\nb")])))
        XCTAssertNotNil(LinkFraming.encode(LinkMessage(.hello, [("phone.name", "a b")])))
    }

    func testAMalformedHeaderIsRefused() {
        let noMagic = [UInt8]("link.version=1\nlink.message=ping\nlink.bytes=0\n\n".utf8)
        guard case .failure(let e1) = LinkFraming.decode(noMagic, streamEnded: false) else { return XCTFail("no magic accepted") }
        XCTAssertEqual(e1.kind, .malformed)
        let unknown = [UInt8]("# gd-capture-bundle\nlink.version=1\nlink.message=hullo\nlink.bytes=0\n\n".utf8)
        guard case .failure(let e2) = LinkFraming.decode(unknown, streamEnded: false) else { return XCTFail("unknown accepted") }
        XCTAssertEqual(e2.kind, .malformed)
        let duplicate = [UInt8]("# gd-capture-bundle\nlink.version=1\nlink.message=ping\nlink.bytes=0\nlink.bytes=0\n\n".utf8)
        guard case .failure(let e3) = LinkFraming.decode(duplicate, streamEnded: false) else { return XCTFail("duplicate accepted") }
        XCTAssertEqual(e3.kind, .malformed)
    }
}
