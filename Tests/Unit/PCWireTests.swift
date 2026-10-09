#if DEBUG
import Foundation
import Security
import UIKit
import XCTest
@testable import GaussiansCapture

// Drops every pong the phone sends, and reports it sent.
final class PongSwallowingTransport: LinkTransport {
    private let inner: LinkTransport

    init(_ inner: LinkTransport) {
        self.inner = inner
    }

    var events: ((LinkTransportEvent) -> Void)? {
        get { inner.events }
        set { inner.events = newValue }
    }

    func start(queue: DispatchQueue) {
        inner.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        if case .success(.message(let m, _)) = LinkFraming.decode([UInt8](data), streamEnded: true), m.type == .pong {
            completion(nil)
            return
        }
        inner.send(data, completion: completion)
    }

    func cancel() {
        inner.cancel()
    }
}

struct PongSwallowingDialer: LinkDialer {
    func dial(_ target: LinkTarget) -> LinkTransport {
        PongSwallowingTransport(NWLinkDialer().dial(target))
    }
}

// The app's link against the PC's own recordings.
final class PCWireTests: XCTestCase {
    static let token = "00112233445566778899aabbccddeeff"
    let suite = "gc-tests-pc-wire"
    var store: PairingStore!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = PairingStore(service: "com.vkorytsko.gaussianscapture.pc.pcwiretest", defaults: defaults)
        store.forget()
    }

    override func tearDown() {
        store.forget()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func client(_ dialer: LinkDialer = NWLinkDialer()) -> LinkClient {
        LinkClient(dialer: dialer, reader: DiskRecordReader(), clock: SystemLinkClock(), store: store,
                   phoneName: "iPhone", appVersion: "0.2.0+1")
    }

    func status(_ c: LinkClient) -> LinkStatus {
        c.queue.sync { c.status() }
    }

    struct MainRun {
        let pc: ScriptedPC
        let client: LinkClient
        let take: URL
        let root: URL
    }

    // Pairs by code against main's first connection, which cuts the take inside record 2, then
    // resumes by token against its second, which ends the link after the take.
    func runMain(_ dialer: LinkDialer = NWLinkDialer()) throws -> MainRun {
        let main = try PCRecording.load("main")
        let pc = ScriptedPC(plays: [ScriptedPC.Play(recording: main, connection: 1),
                                    ScriptedPC.Play(recording: main, connection: 2)])
        let port = try pc.start()
        let root = try TestFiles.temporaryRoot("pc-main")
        let c = client(dialer)
        c.pair(target: .hostPort("127.0.0.1", port), code: "246813")
        let take = try writeThreeRecordTake(root: root, listener: c)
        let ended = expectation(description: "the second connection ended")
        pc.onEnded = { n in if n == 2 { ended.fulfill() } }
        c.setForeground(true)
        wait(for: [ended], timeout: 40)
        // The PC's last message arrives before its close; the link reads it before it is closed here.
        let last = try XCTUnwrap(main.messages(2)?.last?.message)
        waitUntil(5, "the PC's last message") { c.queue.sync { c.lastProgress } == last }
        c.disconnect()
        return MainRun(pc: pc, client: c, take: take, root: root)
    }

    func testPairingAndResumeAgainstThePCsRecording() throws {
        let run = try runMain()
        defer { run.pc.stop() }
        let first = run.pc.observed(1)
        let second = run.pc.observed(2)
        XCTAssertNil(first.failure)
        XCTAssertNil(second.failure)
        XCTAssertEqual(first.endedBy, "pc")
        XCTAssertEqual(second.endedBy, "pc")

        XCTAssertEqual(store.token(), PCWireTests.token)
        XCTAssertEqual(store.pcName, "TEST-PC")
        XCTAssertEqual(first.accepted.first?.value("pair.code"), "246813")
        XCTAssertEqual(second.accepted.first?.value("pair.token"), PCWireTests.token)
        XCTAssertNil(second.accepted.first?.value("pair.code"))
        XCTAssertEqual(recordIndexes(first.accepted), [0, 1])
        XCTAssertEqual(recordIndexes(second.accepted), [2])
        XCTAssertEqual(second.accepted.last?.type, .takeStop)
        XCTAssertEqual(second.accepted.last?.value("last"), "2")

        let rebuilt = run.root.appendingPathComponent("rebuilt", isDirectory: true)
        XCTAssertTrue(rebuildTake(from: first.accepted + second.accepted, into: rebuilt))
        XCTAssertEqual(takeDifferences(run.take, rebuilt), [])
        // The failing case: without the record sent after the resume, the take is not rebuilt.
        let short = run.root.appendingPathComponent("short", isDirectory: true)
        XCTAssertTrue(rebuildTake(from: first.accepted, into: short))
        XCTAssertFalse(takeDifferences(run.take, short).isEmpty)
    }

    // The progress and thumbnail the app keeps are the recording's last, field for field.
    func testTheAppKeepsThePCsProgressAndThumbnail() throws {
        let run = try runMain()
        defer { run.pc.stop() }
        let messages = try XCTUnwrap(PCRecording.load("main").messages(2)).map { $0.message }
        let lastProgress = try XCTUnwrap(messages.last(where: { $0.type == .progress }))
        let thumbnail = try XCTUnwrap(messages.last(where: { $0.type == .thumbnail }))
        let kept = run.client.queue.sync { (run.client.lastProgress, run.client.lastThumbnail) }
        XCTAssertEqual(kept.0, lastProgress)
        XCTAssertEqual(kept.1, thumbnail)
        XCTAssertEqual(status(run.client).behindS, 0.369)
        // The failing case: the first progress of the take differs from the last.
        let firstProgress = try XCTUnwrap(messages.first(where: { $0.type == .progress }))
        XCTAssertNotEqual(kept.0, firstProgress)
    }

    func testEveryPingIsAnswered() throws {
        let run = try runMain()
        defer { run.pc.stop() }
        for n in [1, 2] {
            let o = run.pc.observed(n)
            XCTAssertGreaterThanOrEqual(o.pcPingsSent, 1, "connection \(n)")
            XCTAssertEqual(o.phonePongs, o.pcPingsSent, "connection \(n)")
        }
    }

    // The failing case of the check above: a transport that swallows pongs leaves the PC's pings
    // unanswered.
    func testASwallowedPongIsSeen() throws {
        let run = try runMain(PongSwallowingDialer())
        defer { run.pc.stop() }
        let unanswered = [1, 2].map { run.pc.observed($0) }.filter { $0.phonePongs < $0.pcPingsSent }
        XCTAssertFalse(unanswered.isEmpty)
    }

    // A PC silent after record 1: the link drops after its unanswered pings, retries through a busy
    // refusal, and resumes at have=1.
    func testASilentPCIsDroppedAndTheTakeResumes() throws {
        let main = try PCRecording.load("main")
        let busy = try PCRecording.load("busy")
        let pc = ScriptedPC(plays: [ScriptedPC.Play(recording: main, connection: 1, silentAfterRecords: 2),
                                    ScriptedPC.Play(recording: busy, connection: 1),
                                    ScriptedPC.Play(recording: main, connection: 2)])
        let port = try pc.start()
        defer { pc.stop() }
        let root = try TestFiles.temporaryRoot("pc-silent")
        let c = client()
        defer { c.disconnect() }
        c.pair(target: .hostPort("127.0.0.1", port), code: "246813")
        _ = try writeThreeRecordTake(root: root, listener: c)
        let ended = expectation(description: "the resumed connection ended")
        pc.onEnded = { n in if n == 3 { ended.fulfill() } }
        c.setForeground(true)
        wait(for: [ended], timeout: 60)

        let silent = pc.observed(1)
        let since = try XCTUnwrap(silent.silentSince)
        let endedAt = try XCTUnwrap(silent.endedAt)
        XCTAssertEqual(silent.endedBy, "phone")
        XCTAssertGreaterThanOrEqual(endedAt - since, 8)
        XCTAssertLessThanOrEqual(endedAt - since, 10.6)
        XCTAssertEqual(pc.observed(2).endedBy, "pc")
        XCTAssertEqual(pc.observed(3).accepted.first?.value("pair.token"), PCWireTests.token)
        XCTAssertEqual(recordIndexes(pc.observed(3).accepted), [2])
    }

    // The control: a PC that still answers pings after record 1 is not dropped.
    func testAPCThatStillAnswersIsNotDropped() throws {
        let main = try PCRecording.load("main")
        let pc = ScriptedPC(plays: [ScriptedPC.Play(recording: main, connection: 1, silentAfterRecords: 2,
                                                    answerPingsWhileSilent: true)])
        let port = try pc.start()
        defer { pc.stop() }
        let root = try TestFiles.temporaryRoot("pc-answering")
        let c = client()
        defer { c.disconnect() }
        c.pair(target: .hostPort("127.0.0.1", port), code: "246813")
        _ = try writeThreeRecordTake(root: root, listener: c)
        c.setForeground(true)
        waitUntil(10, "record 1") { pc.observed(1).silentSince != nil }
        RunLoop.current.run(until: Date().addingTimeInterval(12))
        XCTAssertNil(pc.observed(1).endedAt)
        XCTAssertEqual(status(c).phase, .connected)
    }

    // Each refusal shows its reason and its state line; only token deletes the token.
    func testEachRefusal() throws {
        let cases: [(recording: String, byToken: Bool, phase: LinkStatus.Phase, title: String, tokenKept: Bool)] = [
            ("code", false, .refused("code"), "Refused: wrong code", false),
            ("token", true, .refused("token"), "Refused: this phone was forgotten", false),
            ("busy", true, .refused("busy"), "Refused: busy", true),
            ("stale", true, .refused("version"), "Refused: versions differ", true),
        ]
        for c in cases {
            store.forget()
            let pc = ScriptedPC(plays: [ScriptedPC.Play(recording: try PCRecording.load(c.recording), connection: 1)])
            let port = try pc.start()
            if c.byToken {
                XCTAssertEqual(store.setToken(PCWireTests.token), errSecSuccess)
                store.target = .hostPort("127.0.0.1", port)
            }
            let link = client()
            if !c.byToken {
                link.pair(target: .hostPort("127.0.0.1", port), code: "111111")
            }
            link.setForeground(true)
            waitUntil(10, c.recording + " refusal") { status(link).phase == c.phase }
            let s = status(link)
            XCTAssertEqual(s.phase, c.phase, c.recording)
            XCTAssertEqual(LinkText.line(s).title, c.title, c.recording)
            XCTAssertEqual(store.token() != nil, c.tokenKept, c.recording)
            XCTAssertEqual(s.paired, c.tokenKept, c.recording)
            if c.recording == "stale" {
                XCTAssertEqual(LinkText.line(s).detail, "link.version=0 is not this end's link.version=1")
            }
            link.disconnect()
            pc.stop()
        }
    }

    // Every message the PC recorded decodes, in the script's order; the failing cases are another
    // version and a cut payload.
    func testEveryRecordedPCMessageDecodes() throws {
        for name in ["main", "stale", "code", "token", "busy"] {
            let r = try PCRecording.load(name)
            XCTAssertNil(WireScript.problem(r.script), name)
            for n in r.pcBytes.keys.sorted() {
                let messages = try XCTUnwrap(r.messages(n), "\(name) connection \(n)")
                let expected = r.events(n).filter { $0.count == 3 && $0[1] == "pc" }.map { $0[2] }
                XCTAssertEqual(messages.map { $0.message.type.rawValue }, expected, "\(name) connection \(n)")
                for (m, _) in messages {
                    switch m.type {
                    case .progress:
                        for key in ["iteration", "splats", "frames"] {
                            XCTAssertNotNil(m.value(key).flatMap { Int($0) }, key)
                        }
                        XCTAssertNotNil(m.value("loss").flatMap { Double($0) })
                        if let p = m.value("psnr_db") { XCTAssertNotNil(Double(p)) }
                        if let b = m.value("behind_s") { XCTAssertNotNil(Double(b)) }
                    case .thumbnail:
                        XCTAssertNotNil(m.value("iteration").flatMap { Int($0) })
                        XCTAssertEqual(Array(m.payload.prefix(2)), [0xFF, 0xD8])
                        XCTAssertEqual(Array(m.payload.suffix(2)), [0xFF, 0xD9])
                    default:
                        break
                    }
                }
            }
        }
        let bytes = try XCTUnwrap(PCRecording.load("main").pcBytes[2])
        let text = String(decoding: bytes.prefix(40), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# gd-capture-bundle\nlink.version=1\n"))
        var other = bytes
        other[other.firstIndex(of: UInt8(ascii: "1"))!] = UInt8(ascii: "2")
        XCTAssertEqual(LinkFraming.decode(other, streamEnded: false),
                       .failure(LinkError(kind: .version, text: "link.version=2 is not this end's link.version=1")))
        let messages = try XCTUnwrap(PCRecording.load("main").messages(2))
        let before = messages.prefix(while: { $0.message.type != .thumbnail }).reduce(0) { $0 + $1.raw.count }
        let thumbnail = try XCTUnwrap(messages.first(where: { $0.message.type == .thumbnail })).raw
        let cut = Array(bytes[before..<(before + thumbnail.count - 100)])
        XCTAssertEqual(LinkFraming.decode(cut, streamEnded: false), .success(.incomplete))
        guard case .failure(let e) = LinkFraming.decode(cut, streamEnded: true) else {
            return XCTFail("a cut thumbnail decoded")
        }
        XCTAssertEqual(e.kind, .cutOff)
        let whole = Array(bytes[before..<(before + thumbnail.count)])
        guard case .success(.message(let m, _)) = LinkFraming.decode(whole, streamEnded: true) else {
            return XCTFail("the whole thumbnail did not decode")
        }
        XCTAssertEqual(m.type, .thumbnail)
    }

    func testTheRecordedQRCodeParses() throws {
        let qr = try XCTUnwrap(PCRecording.load("main").qr).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(PairingURL.parse(qr), PairingTarget(host: "127.0.0.1", port: 7420, code: "246813"))
        // The failing case: the same URL with a five-digit code.
        XCTAssertNil(PairingURL.parse(qr.replacingOccurrences(of: "code=246813", with: "code=24681")))
    }

    // Every figure the Training tab shows is the recorded progress's own text, and its image is the
    // recorded thumbnail's JPEG, byte for byte.
    func testTheTrainingTabShowsTheRecordedProgressAndThumbnail() throws {
        let run = try runMain()
        defer { run.pc.stop() }
        let main = try PCRecording.load("main")
        let messages = try XCTUnwrap(main.messages(2)).map { $0.message }
        let progress = try XCTUnwrap(messages.last(where: { $0.type == .progress }))
        let thumbnail = try XCTUnwrap(messages.last(where: { $0.type == .thumbnail }))
        let s = status(run.client)

        // runMain disconnects at the end: the last figures stay, dimmed.
        XCTAssertEqual(TrainingText.state(s), .down)
        let shown = TrainingText.figures(s.progress)
        XCTAssertEqual(shown, [
            TrainingText.Figure(label: "iteration", value: try XCTUnwrap(progress.value("iteration"))),
            TrainingText.Figure(label: "splats", value: try XCTUnwrap(progress.value("splats"))),
            TrainingText.Figure(label: "frames trained on", value: try XCTUnwrap(progress.value("frames"))),
            TrainingText.Figure(label: "held-out PSNR", value: try XCTUnwrap(progress.value("psnr_db")) + " dB"),
            TrainingText.Figure(label: "loss", value: try XCTUnwrap(progress.value("loss"))),
        ])
        let shownImage = try XCTUnwrap(s.thumbnail?.payload)
        XCTAssertEqual(shownImage, thumbnail.payload)
        XCTAssertNotNil(UIImage(data: shownImage))
        let shownThumbnail = try XCTUnwrap(s.thumbnail)
        let iteration = try XCTUnwrap(thumbnail.value("iteration"))
        XCTAssertEqual(TrainingText.caption(shownThumbnail, arrivedAt: 100, now: 103.9),
                       "the PC's render \u{00B7} iter " + iteration + " \u{00B7} 3 s ago")

        // The failing cases: the take's first progress, before any held-out PSNR, shows other figures
        // and a dash; one byte changed in the image is not the recorded JPEG.
        let early = try XCTUnwrap(try XCTUnwrap(main.messages(1)).map { $0.message }.first(where: { $0.type == .progress }))
        let earlyShown = TrainingText.figures(early)
        XCTAssertNotEqual(earlyShown, shown)
        XCTAssertEqual(earlyShown[3].value, TrainingText.missing)
        var damaged = thumbnail.payload
        damaged[damaged.startIndex + damaged.count / 2] ^= 0xFF
        XCTAssertNotEqual(shownImage, damaged)
    }

    func testTheTrainingTabsStates() {
        var s = LinkStatus()
        XCTAssertEqual(TrainingText.state(s), .unpaired)
        s.paired = true
        s.phase = .connected
        XCTAssertEqual(TrainingText.state(s), .waiting)
        XCTAssertEqual(TrainingText.figures(nil).map { $0.value }, Array(repeating: TrainingText.missing, count: 5))
        s.progress = LinkMessage(.progress, [("iteration", "12"), ("splats", "340"), ("frames", "3"), ("loss", "0.500000")])
        XCTAssertEqual(TrainingText.state(s), .live)
        s.phase = .reconnecting
        XCTAssertEqual(TrainingText.state(s), .down)
        s.paired = false
        XCTAssertEqual(TrainingText.state(s), .unpaired)
        XCTAssertEqual(TrainingText.figures(s.progress).map { $0.value }, ["12", "340", "3", TrainingText.missing, "0.500000"])
    }
}
#endif
