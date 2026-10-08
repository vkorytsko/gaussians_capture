import XCTest
@testable import GaussiansCapture

// A transport that records what the client sends and lets the test play the PC.
final class FakeTransport: LinkTransport {
    var events: ((LinkTransportEvent) -> Void)?
    private(set) var sent: [Data] = []
    private(set) var cancelled = false
    private var queue: DispatchQueue?

    func start(queue: DispatchQueue) {
        self.queue = queue
    }

    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        sent.append(data)
        completion(nil)
    }

    func cancel() {
        cancelled = true
    }

    // On the client's queue, as a real transport's events are.
    func emit(_ event: LinkTransportEvent) {
        queue?.sync { self.events?(event) }
    }

    func emit(_ message: LinkMessage) {
        emit(.received(LinkFraming.encode(message)!))
    }

    var messages: [LinkMessage] {
        sent.compactMap { data in
            if case .success(.message(let m, _)) = LinkFraming.decode([UInt8](data), streamEnded: true) { return m }
            return nil
        }
    }

    func count(_ type: LinkMessageType) -> Int {
        messages.filter { $0.type == type }.count
    }
}

final class FakeDialer: LinkDialer {
    private(set) var made: [FakeTransport] = []

    func dial(_ target: LinkTarget) -> LinkTransport {
        let t = FakeTransport()
        made.append(t)
        return t
    }
}

final class ManualClock: LinkClock {
    private(set) var now = 100.0
    private var tick: (() -> Void)?
    private var queue: DispatchQueue?

    func start(every interval: Double, on queue: DispatchQueue, _ tick: @escaping () -> Void) {
        self.queue = queue
        self.tick = tick
    }

    func advance(to t: Double) {
        queue?.sync {
            now = t
            tick?()
        }
    }
}

struct FakeReader: RecordReader {
    func manifest(in take: URL) -> Data? {
        Data("# gd-capture-bundle\nrecord.kind=manifest\n\n".utf8)
    }

    func record(_ index: Int, in take: URL) -> Data? {
        Data("# gd-capture-bundle\nframe.index=\(index)\nframe.timestamp_s=99.5\n\n".utf8)
    }
}

final class LinkClientTests: XCTestCase {
    let suite = "gc-tests-link"
    var store: PairingStore!
    var dialer: FakeDialer!
    var clock: ManualClock!
    var client: LinkClient!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = PairingStore(service: "com.vkorytsko.gaussianscapture.pc.linktest", defaults: defaults)
        store.forget()
        dialer = FakeDialer()
        clock = ManualClock()
        client = LinkClient(dialer: dialer, reader: FakeReader(), clock: clock, store: store,
                            phoneName: "iPhone", appVersion: "0.2.0+1")
    }

    override func tearDown() {
        store.forget()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func settle() {
        client.queue.sync {}
    }

    // Paired by code, welcomed with a token, one take committed: the client has offered it.
    func connectAndOffer() -> FakeTransport {
        client.pair(target: .hostPort("pc", 7420), code: "246813")
        client.takeCommitted(directory: URL(fileURLWithPath: "/take"), captureId: "c1", index: 0)
        client.setForeground(true)
        settle()
        XCTAssertEqual(dialer.made.count, 1)
        let t = dialer.made[0]
        t.emit(.ready)
        t.emit(LinkMessage(.welcome, [("pc.name", "TEST-PC"), ("pair.token", LinkProtocolTests.token)]))
        return t
    }

    func testPairingSendsTheCodeOnceAndStoresTheToken() {
        let t = connectAndOffer()
        XCTAssertEqual(t.messages.first, LinkMessage(.hello, [("phone.name", "iPhone"), ("app.version", "0.2.0+1"),
                                                             ("pair.code", "246813")]))
        XCTAssertEqual(store.token(), LinkProtocolTests.token)
        XCTAssertEqual(store.pcName, "TEST-PC")
        XCTAssertEqual(t.count(.takeStart), 1)
    }

    // A take refused busy is offered again 5 s later, and not before.
    func testABusyTakeIsOfferedAgainAfterFiveSeconds() {
        let t = connectAndOffer()
        t.emit(LinkMessage(.takeRefused, [("reason", "busy"), ("detail", "a session is running")]))
        clock.advance(to: 104.9)
        XCTAssertEqual(t.count(.takeStart), 1)
        clock.advance(to: 105.0)
        XCTAssertEqual(t.count(.takeStart), 2)

        // Accepted: record 0 goes with its age on the same clock, then take.stop once the take ends.
        t.emit(LinkMessage(.takeAccepted, [("have", "-1")]))
        let records = t.messages.filter { $0.type == .record }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.value("age_ms"), "5500")
        XCTAssertEqual(t.count(.takeStop), 0)
        client.takeEnded(directory: URL(fileURLWithPath: "/take"), captureId: "c1", last: 0)
        settle()
        XCTAssertEqual(t.messages.filter { $0.type == .takeStop }.first?.value("last"), "0")
    }

    // A hello refused busy is retried every 0.5 s.
    func testABusyHelloIsRetriedAfterHalfASecond() {
        client.pair(target: .hostPort("pc", 7420), code: "246813")
        client.setForeground(true)
        settle()
        let t = dialer.made[0]
        t.emit(.ready)
        t.emit(LinkMessage(.refused, [("reason", "busy")]))
        XCTAssertTrue(t.cancelled)
        clock.advance(to: 100.4)
        XCTAssertEqual(dialer.made.count, 1)
        clock.advance(to: 100.5)
        XCTAssertEqual(dialer.made.count, 2)
    }

    // A link that drops resumes by token from the PC's have + 1.
    func testADroppedLinkResumesByTokenFromHavePlusOne() {
        let t = connectAndOffer()
        client.takeCommitted(directory: URL(fileURLWithPath: "/take"), captureId: "c1", index: 1)
        client.takeCommitted(directory: URL(fileURLWithPath: "/take"), captureId: "c1", index: 2)
        t.emit(LinkMessage(.takeAccepted, [("have", "-1")]))
        XCTAssertEqual(t.count(.record), 3)
        t.emit(.ended(nil))
        clock.advance(to: 100.5)
        XCTAssertEqual(dialer.made.count, 2)
        let t2 = dialer.made[1]
        t2.emit(.ready)
        XCTAssertEqual(t2.messages.first?.value("pair.token"), LinkProtocolTests.token)
        XCTAssertNil(t2.messages.first?.value("pair.code"))
        t2.emit(LinkMessage(.welcome, [("pc.name", "TEST-PC")]))
        XCTAssertEqual(t2.count(.takeStart), 1)
        t2.emit(LinkMessage(.takeAccepted, [("have", "1")]))
        let resent = t2.messages.filter { $0.type == .record }
        XCTAssertEqual(resent.count, 1)
        XCTAssertEqual(resent.first.flatMap { TakeLayout.value(String(decoding: $0.payload, as: UTF8.self), "frame.index") },
                       "2")
    }

    // Only a token refusal deletes the token; the failing case is pairing closed, which keeps it.
    func testOnlyATokenRefusalDeletesTheToken() {
        let t = connectAndOffer()
        t.emit(.ended(nil))
        clock.advance(to: 100.5)
        let t2 = dialer.made[1]
        t2.emit(.ready)
        t2.emit(LinkMessage(.refused, [("reason", "pairing closed")]))
        XCTAssertEqual(store.token(), LinkProtocolTests.token)
        XCTAssertEqual(client.queue.sync { client.status().phase }, .refused("pairing closed"))

        client.connect()
        settle()
        let t3 = dialer.made[2]
        t3.emit(.ready)
        t3.emit(LinkMessage(.refused, [("reason", "token")]))
        XCTAssertNil(store.token())
        XCTAssertEqual(client.queue.sync { client.status().phase }, .refused("token"))
    }

    func testTheResumeCursor() {
        var c = TakeCursor(directory: URL(fileURLWithPath: "/take"), captureId: "c1")
        XCTAssertNil(c.due)
        XCTAssertTrue(c.accept(have: -1))
        XCTAssertNil(c.due)
        c.noteCommitted(0)
        c.noteCommitted(2)
        c.noteCommitted(1)
        XCTAssertEqual(c.due, 0)
        c.sent(0)
        XCTAssertEqual(c.due, 1)
        c.sent(5)
        XCTAssertEqual(c.due, 1)
        c.connectionLost()
        XCTAssertNil(c.due)
        XCTAssertEqual(c.waiting, 3)
        XCTAssertTrue(c.accept(have: 1))
        XCTAssertEqual(c.due, 2)
        c.sent(2)
        XCTAssertNil(c.due)
        XCTAssertFalse(c.stopDue)
        c.noteEnded(last: 2)
        XCTAssertTrue(c.stopDue)
        XCTAssertEqual(c.waiting, 0)
    }

    // The failing case: the PC claims a record this phone never committed.
    func testTheCursorRefusesAHaveBeyondWhatIsCommitted() {
        var c = TakeCursor(directory: URL(fileURLWithPath: "/take"), captureId: "c1")
        c.noteCommitted(2)
        XCTAssertFalse(c.accept(have: 3))
        XCTAssertFalse(c.accept(have: -2))
        XCTAssertNil(c.due)
    }
}
