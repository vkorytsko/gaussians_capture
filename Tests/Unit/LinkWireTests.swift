#if DEBUG
import Foundation
import XCTest
@testable import GaussiansCapture

// Returns record 2's bytes where record 1 is due: a reader that skips a record.
struct SkippingReader: RecordReader {
    let inner = DiskRecordReader()

    func manifest(in take: URL) -> Data? {
        inner.manifest(in: take)
    }

    func record(_ index: Int, in take: URL) -> Data? {
        inner.record(index == 1 ? 2 : index, in: take)
    }
}

final class LinkWireTests: XCTestCase {
    static let code = "246813"
    static let token = "00112233445566778899aabbccddeeff"
    static let pcName = "TEST-PC"

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

    // A three-record synthetic take, paired by code with the PC, cut inside record 2, resumed by token
    // from have=1, and stopped. The recording of both sides, with the take, is the CI artifact app-wire.
    func testPairCutAndResume() throws {
        let fm = FileManager.default
        let root = try TestFiles.temporaryRoot("wire")
        let pc = LoopbackPC(code: LinkWireTests.code, token: LinkWireTests.token, pcName: LinkWireTests.pcName,
                            cut: (connection: 1, index: 2), received: root.appendingPathComponent("received", isDirectory: true))
        let port = try pc.start()
        defer { pc.stop() }

        let suite = "gc-tests-wire"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PairingStore(service: "com.vkorytsko.gaussianscapture.pc.wiretest", defaults: defaults)
        store.forget()
        defer {
            store.forget()
            defaults.removePersistentDomain(forName: suite)
        }
        #if PLANT_SKIP_RECORD
        let reader: RecordReader = SkippingReader()
        #else
        let reader: RecordReader = DiskRecordReader()
        #endif
        let client = LinkClient(dialer: NWLinkDialer(), reader: reader, clock: SystemLinkClock(), store: store,
                                phoneName: "iPhone", appVersion: "0.2.0+1")
        defer { client.disconnect() }
        client.pair(target: .hostPort("127.0.0.1", port), code: LinkWireTests.code)

        // The take is written whole before the app comes to the foreground, so the stream is the same
        // on every run.
        let takes = root.appendingPathComponent("takes", isDirectory: true)
        try fm.createDirectory(at: takes, withIntermediateDirectories: true)
        let source = ReplayFrameSource(scene: .small, keepLimit: 3)
        let pipeline = CapturePipeline(source: source, root: takes)
        pipeline.commitListener = client
        pipeline.writeQueue.sync {}
        source.start()
        pipeline.beginTake(TakeInfo.make(now: Date(), fpsNominal: KeepRule.framesPerSecond, timestamps: source.timestampSource))
        waitUntil(15, "three records") {
            let names = (try? fm.contentsOfDirectory(atPath: takes.path)) ?? []
            return names.contains { name in
                let records = takes.appendingPathComponent(name).appendingPathComponent("records")
                let headers = ((try? fm.contentsOfDirectory(atPath: records.path)) ?? []).filter { $0.hasSuffix(".txt") }
                return headers.count == 3
            }
        }
        var ended: TakeResult?
        let finished = expectation(description: "take finished")
        pipeline.endTake { result in
            ended = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        source.stop()
        let result = try XCTUnwrap(ended)
        XCTAssertEqual(result.framesWritten, 3)
        let takeName = try XCTUnwrap(result.name)
        let take = takes.appendingPathComponent(takeName, isDirectory: true)

        let stopped = expectation(description: "take.stop received")
        pc.onTakeStop = { stopped.fulfill() }
        client.setForeground(true)
        wait(for: [stopped], timeout: 30)
        waitUntil(10, "the take to be confirmed") { client.queue.sync { client.status().captureId == nil } }
        let closed = expectation(description: "second connection closed")
        pc.onConnectionEnded = { n in if n == 2 { closed.fulfill() } }
        client.disconnect()
        wait(for: [closed], timeout: 10)

        XCTAssertEqual(store.token(), LinkWireTests.token)
        XCTAssertEqual(pc.queue.sync { pc.recordsByConnection[1] }, [0, 1])
        XCTAssertEqual(pc.queue.sync { pc.recordsByConnection[2] }, [2])
        XCTAssertEqual(pc.queue.sync { pc.takeStops }, ["2"])
        let script = pc.recorder.script
        XCTAssertNil(WireScript.problem(script), script.joined(separator: "\n"))
        XCTAssertTrue(script.contains("1 end cut phone"), script.joined(separator: "\n"))
        XCTAssertTrue(script.contains("2 end close phone"), script.joined(separator: "\n"))
        let received = root.appendingPathComponent("received", isDirectory: true)
        XCTAssertEqual(takeDifferences(take, received), [])

        // The failing case: the received take with one record's colour gone no longer equals the app's.
        let damaged = root.appendingPathComponent("damaged", isDirectory: true)
        try TestFiles.replace(damaged, withCopyOf: received)
        try fm.removeItem(at: damaged.appendingPathComponent("records/000001.color.jpg"))
        XCTAssertEqual(takeDifferences(take, damaged), ["only on one side: records/000001.color.jpg"])

        let artifact = try TestFiles.artifactDirectory().appendingPathComponent("app-wire", isDirectory: true)
        if fm.fileExists(atPath: artifact.path) { try fm.removeItem(at: artifact) }
        try pc.recorder.write(to: artifact)
        try fm.copyItem(at: take, to: artifact.appendingPathComponent("take", isDirectory: true))
        print("wire recording copied to " + artifact.path)
    }

    // The script format, and its failing cases.
    func testTheWireScriptFormat() throws {
        let recorder = WireRecorder()
        let n = recorder.open()
        recorder.message(n, "phone", "hello", Data([1, 2]))
        recorder.message(n, "pc", "welcome", Data([3]))
        recorder.partial(n, "phone", Data([4]))
        recorder.end(n, "cut", "phone")
        let dir = try TestFiles.temporaryRoot("script")
        try recorder.write(to: dir)
        let lines = try WireScript.read(dir)
        XCTAssertEqual(lines, ["wire-script 1", "1 phone hello", "1 pc welcome", "1 end cut phone"])
        XCTAssertNil(WireScript.problem(lines))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("conn-1.phone.bin")), Data([1, 2, 4]))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("conn-1.pc.bin")), Data([3]))
        for bad in [["wire-script 2"], ["wire-script 1", "1 phone hullo"], ["wire-script 1", "0 phone hello"],
                    ["wire-script 1", "1 laptop hello"], ["wire-script 1", "1 end vanished phone"],
                    ["wire-script 1", "01 phone hello"]] {
            XCTAssertNotNil(WireScript.problem(bad), bad.joined(separator: " / "))
        }
    }

    // Hook for the PC's recording: what the PC sends a phone, recorded by the PC on a synthetic take, is
    // copied here as Tests/Fixtures/pc-wire/ and played by a scripted PC. Nothing to play until then.
    func testAgainstThePCRecording() throws {
        guard Bundle(for: LinkWireTests.self).url(forResource: "script", withExtension: "txt", subdirectory: "pc-wire") != nil else {
            throw XCTSkip("no PC wire recording in the test bundle yet")
        }
        XCTFail("a PC wire recording is present, and no test plays it yet")
    }
}
#endif
