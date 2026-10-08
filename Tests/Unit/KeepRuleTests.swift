import XCTest
@testable import GaussiansCapture

final class KeepRuleTests: XCTestCase {
    func testTheFirstFrameIsDue() {
        XCTAssertTrue(KeepRule.isDue(123.0, lastDue: nil))
    }

    // Due from 1/fps minus 2 ms after the last due frame; one tenth of a millisecond earlier is not.
    func testTheIntervalBoundary() {
        let last = 1000.0
        XCTAssertTrue(KeepRule.isDue(last + 0.25 - 0.002, lastDue: last))
        XCTAssertTrue(KeepRule.isDue(last + 0.25, lastDue: last))
        XCTAssertFalse(KeepRule.isDue(last + 0.25 - 0.0021, lastDue: last))
        XCTAssertFalse(KeepRule.isDue(last + 0.1, lastDue: last))
    }

    // 60 frames a second for 10 s keeps every 15th: 40 frames, 0.25 s apart.
    func testA60HzStreamKeepsFourFramesASecond() {
        let keeping = KeepState(pool: FramePool(capacity: 3))
        var kept: [Double] = []
        for n in 0..<600 {
            let t = 500.0 + Double(n) / 60.0
            if keeping.claim(t) { kept.append(t) }
        }
        XCTAssertEqual(kept.count, 40)
        XCTAssertEqual(keeping.claimed, 40)
        for (a, b) in zip(kept, kept.dropFirst()) {
            XCTAssertEqual(b - a, 0.25, accuracy: 1e-9)
        }
    }

    // The rule reads timestamps, so frames the camera itself skipped do not shift what is kept.
    func testSkippedSourceFramesDoNotShiftTheRate() {
        let keeping = KeepState(pool: FramePool(capacity: 3))
        var kept: [Double] = []
        for n in 0..<600 where n % 7 != 3 {
            let t = 500.0 + Double(n) / 60.0
            if keeping.claim(t) { kept.append(t) }
        }
        for (a, b) in zip(kept, kept.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.25 - 0.002)
            XCTAssertLessThan(b - a, 0.25 + 2.0 / 60.0)
        }
        XCTAssertGreaterThanOrEqual(kept.count, 36)
    }

    func testThePoolLendsAtMostItsCapacity() throws {
        let pool = FramePool(capacity: 3)
        var held: [PoolSlot] = []
        for _ in 0..<3 {
            held.append(try XCTUnwrap(pool.borrow()))
        }
        // The failing case of back-pressure: a fourth frame finds no slot.
        XCTAssertNil(pool.borrow())
        XCTAssertEqual(pool.outstandingCount, 3)
        held[0].release()
        held[0].release()
        XCTAssertEqual(pool.outstandingCount, 2)
        let again = pool.borrow()
        XCTAssertNotNil(again)
        XCTAssertEqual(pool.outstandingCount, 3)
        XCTAssertEqual(pool.peakOutstanding, 3)
        withExtendedLifetime(held) {}
        withExtendedLifetime(again) {}
    }

    func testASlotDroppedWithoutReleaseStillComesBack() {
        let pool = FramePool(capacity: 1)
        do {
            let slot = pool.borrow()
            XCTAssertNotNil(slot)
            XCTAssertNil(pool.borrow())
        }
        XCTAssertEqual(pool.outstandingCount, 0)
        XCTAssertNotNil(pool.borrow())
    }
}
