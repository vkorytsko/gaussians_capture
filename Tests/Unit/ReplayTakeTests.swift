#if DEBUG
import Foundation
import XCTest
@testable import GaussiansCapture

// Takes written end to end from synthetic frames: source, keep rule, pool, pipeline, writer, disk.
final class ReplayTakeTests: XCTestCase {
    struct Run {
        let result: TakeResult
        let claimed: Int            // due frames: each is written or counted as dropped
        let peak: Int               // most pool slots out at once
        let take: URL?
    }

    // `writerStall` blocks the writer queue from the start of the take, as a writer too slow to keep up.
    func record(root: URL, seconds: TimeInterval, writerStall: TimeInterval, poolCapacity: Int) throws -> Run {
        let source = ReplayFrameSource()
        let pipeline = CapturePipeline(source: source, root: root)
        pipeline.writeQueue.sync {}
        source.start()
        if writerStall > 0 {
            pipeline.writeQueue.async { Thread.sleep(forTimeInterval: writerStall) }
        }
        let info = TakeInfo.make(now: Date(), fpsNominal: KeepRule.framesPerSecond, timestamps: source.timestampSource)
        let keeping = pipeline.beginTake(info, poolCapacity: poolCapacity)

        let recorded = expectation(description: "recording")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { recorded.fulfill() }
        wait(for: [recorded], timeout: seconds + 10)

        var ended: TakeResult? = nil
        let finished = expectation(description: "take finished")
        pipeline.endTake { result in
            ended = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: writerStall + 60)
        source.stop()
        let claimed = source.queue.sync { keeping.claimed }
        let result = try XCTUnwrap(ended)
        return Run(result: result, claimed: claimed, peak: keeping.pool.peakOutstanding,
                   take: result.name.map { root.appendingPathComponent($0, isDirectory: true) })
    }

    // Also the CI artifact: the take is copied to <artifacts>/replay-take.
    func testAReplayTakeIsWrittenWhole() throws {
        let root = try TestFiles.temporaryRoot("replay")
        let run = try record(root: root, seconds: 8, writerStall: 0, poolCapacity: CapturePipeline.maxPendingFrames)
        XCTAssertNil(run.result.failure)
        XCTAssertEqual(run.result.discarded, 0)
        XCTAssertEqual(run.result.dropped, 0)
        XCTAssertEqual(run.result.framesWritten, run.claimed)
        XCTAssertGreaterThanOrEqual(run.result.framesWritten, 12)
        let take = try XCTUnwrap(run.take)
        XCTAssertEqual(TakeLayout.problems(in: take), [])
        let manifest = try String(contentsOf: take.appendingPathComponent("manifest.txt"), encoding: .utf8)
        XCTAssertNotNil(manifest.range(of: "\ncapture.timestamps=synthesized\n"))
        XCTAssertNotNil(manifest.range(of: "\ncolor.width=320\ncolor.height=240\n"))

        let artifact = try TestFiles.artifactDirectory().appendingPathComponent("replay-take", isDirectory: true)
        try TestFiles.replace(artifact, withCopyOf: take)
        print("replay take copied to " + artifact.path)
    }

    // A writer stalled for 2.5 s holds every slot of the pool: the due frames meanwhile are dropped and
    // counted, and the records on disk stay contiguous. testAReplayTakeIsWrittenWhole is the same take
    // with a writer that keeps up, and drops nothing.
    func testSlowWriterDropsAreCountedAndIndicesStayGapless() throws {
        #if PLANT_UNBOUNDED_POOL
        let capacity = 1_000
        #else
        let capacity = CapturePipeline.maxPendingFrames
        #endif
        let root = try TestFiles.temporaryRoot("slow")
        let run = try record(root: root, seconds: 4, writerStall: 2.5, poolCapacity: capacity)
        XCTAssertNil(run.result.failure)
        XCTAssertEqual(run.peak, CapturePipeline.maxPendingFrames)
        XCTAssertGreaterThanOrEqual(run.result.dropped, 1)
        XCTAssertGreaterThanOrEqual(run.result.framesWritten, CapturePipeline.maxPendingFrames)
        XCTAssertEqual(run.result.framesWritten + run.result.dropped, run.claimed)
        let take = try XCTUnwrap(run.take)
        XCTAssertEqual(TakeLayout.problems(in: take), [])

        // The failing case: the same take with record 1's header gone reads as a gap.
        let cut = root.appendingPathComponent("cut", isDirectory: true)
        try TestFiles.replace(cut, withCopyOf: take)
        try FileManager.default.removeItem(at: cut.appendingPathComponent("records/000001.txt"))
        let problems = TakeLayout.problems(in: cut)
        XCTAssertTrue(problems.contains { $0.contains("a gap") }, problems.joined(separator: "; "))
    }

    func testATakeCutMidRecordIsSweptAtTheNextLaunch() throws {
        let fm = FileManager.default
        let root = try TestFiles.temporaryRoot("sweep")
        let run = try record(root: root, seconds: 1.5, writerStall: 0, poolCapacity: CapturePipeline.maxPendingFrames)
        let take = try XCTUnwrap(run.take)
        let records = take.appendingPathComponent("records", isDirectory: true)
        let committed = try fm.contentsOfDirectory(atPath: records.path).sorted()
        let n = run.result.framesWritten
        XCTAssertGreaterThanOrEqual(n, 2)
        XCTAssertEqual(TakeLayout.problems(in: take), [])

        // Killed between record n's blobs and its header's rename.
        let first = TakeStorage.recordStem(0)
        let next = TakeStorage.recordStem(n)
        for suffix in [".color.jpg", ".depth.f32", ".conf.u8"] {
            try fm.copyItem(at: records.appendingPathComponent(first + suffix),
                            to: records.appendingPathComponent(next + suffix))
        }
        try fm.copyItem(at: records.appendingPathComponent(first + ".txt"),
                        to: records.appendingPathComponent(next + ".txt.tmp"))
        // Killed before its record 0 was committed.
        let early = root.appendingPathComponent("20260101-000000", isDirectory: true)
        try fm.createDirectory(at: early.appendingPathComponent("records", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data("# gd-capture-bundle\n\n".utf8).write(to: early.appendingPathComponent("manifest.txt"))
        try Data([1, 2, 3]).write(to: early.appendingPathComponent("records/000000.color.jpg"))
        // Not a take, so never touched.
        let other = root.appendingPathComponent("notes", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: other.appendingPathComponent("000000.color.jpg"))

        // The failing case: before the sweep, the cut take is not whole.
        XCTAssertEqual(TakeLayout.orphans(in: take).count, 4)
        XCTAssertNotEqual(TakeLayout.problems(in: take), [])

        // The next launch: a new pipeline sweeps its root before anything else on its writer queue.
        let relaunched = CapturePipeline(source: ReplayFrameSource(), root: root)
        relaunched.writeQueue.sync {}

        XCTAssertEqual(TakeLayout.problems(in: take), [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: records.path).sorted(), committed)
        XCTAssertFalse(fm.fileExists(atPath: early.path))
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("000000.color.jpg").path))
    }
}
#endif
