import CoreGraphics
import CoreVideo
import Foundation
import UIKit

enum TrackingLevel {
    case good, limited, lost
}

struct LiveStatus: Equatable {
    var tracking = "starting"
    var level = TrackingLevel.limited
    var coaching: String? = nil
    var depthOK = false
}

struct FrameFormat: Equatable {
    let colorWidth: Int
    let colorHeight: Int
    let depthWidth: Int
    let depthHeight: Int
}

// A pinhole at the stored colour resolution, in pixels.
struct Intrinsics: Equatable {
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
}

// One kept frame, owned by the app: nothing in it belongs to a camera's buffers. Sensor-native
// orientation throughout.
struct CapturedFrame {
    let timestamp: Double
    let format: FrameFormat
    let color: CVPixelBuffer        // the YCbCr planes, copied into the buffer of a pool slot
    let slot: PoolSlot              // returned to the take's pool when the writer is done with the frame
    let intrinsics: Intrinsics
    let rotation: [Double]          // world-from-camera, row-major (pose.r)
    let center: [Double]            // camera centre in world, metres (pose.c)
    let depth: Data                 // f32le metres, depthWidth x depthHeight
    let confidence: Data?           // u8 0/1/2, same size as depth
    let trackingState: String
    let trackingReason: String?
    let exposureDurationS: Double?
    let exposureEvOffset: Double?
    let exposureIso: Double?
}

enum DropReason: String {
    case poolEmpty, noDepth, unusable, formatChanged
}

// The capture rate. A frame is due when its timestamp is at least 1/fps minus the slack after the last
// due one: timestamps, never a frame count, because a source may itself skip frames.
enum KeepRule {
    static let framesPerSecond = 4.0
    static let slack: TimeInterval = 0.002

    static func isDue(_ timestamp: Double, lastDue: Double?, framesPerSecond fps: Double = framesPerSecond) -> Bool {
        guard let last = lastDue else { return true }
        return !(timestamp < last + 1.0 / fps - slack)
    }
}

// Bounds the colour copies a take holds. A source borrows a slot before it copies a frame and drops the
// frame when none is free; the slot comes back when the writer is done with that frame.
final class FramePool {
    let capacity: Int
    private let lock = NSLock()
    private var outstanding = 0
    private var peak = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    func borrow() -> PoolSlot? {
        lock.lock()
        defer { lock.unlock() }
        guard outstanding < capacity else { return nil }
        outstanding += 1
        peak = max(peak, outstanding)
        return PoolSlot(pool: self)
    }

    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding
    }

    var peakOutstanding: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    fileprivate func giveBack() {
        lock.lock()
        outstanding -= 1
        lock.unlock()
    }
}

// One borrowed place in a pool. Released once: explicitly, or when the last reference goes.
final class PoolSlot {
    private let pool: FramePool
    private let lock = NSLock()
    private var held = true

    fileprivate init(pool: FramePool) {
        self.pool = pool
    }

    func release() {
        lock.lock()
        let wasHeld = held
        held = false
        lock.unlock()
        if wasHeld { pool.giveBack() }
    }

    deinit {
        release()
    }
}

// One take's keep state, used on its source's queue only.
final class KeepState {
    let pool: FramePool
    let framesPerSecond: Double
    private(set) var lastDue: Double? = nil
    private(set) var claimed = 0

    init(pool: FramePool, framesPerSecond: Double = KeepRule.framesPerSecond) {
        self.pool = pool
        self.framesPerSecond = framesPerSecond
    }

    // True for a due frame. A due frame starts the next interval whether it is then kept or dropped.
    func claim(_ timestamp: Double) -> Bool {
        guard KeepRule.isDue(timestamp, lastDue: lastDue, framesPerSecond: framesPerSecond) else { return false }
        lastDue = timestamp
        claimed += 1
        return true
    }
}

// Every call arrives on the source's queue.
protocol FrameSink: AnyObject {
    func frameSource(_ source: FrameSource, captured frame: CapturedFrame)
    func frameSource(_ source: FrameSource, dropped reason: DropReason)
    func frameSource(_ source: FrameSource, status: LiveStatus)
    func frameSource(_ source: FrameSource, depthOverlay: CGImage?)
    func frameSourceInterrupted(_ source: FrameSource)
    func frameSource(_ source: FrameSource, failed message: String)
}

// Where frames come from. Per due frame a source runs its take's KeepState, borrows a pool slot, copies
// the frame into it and hands the copy to its sink, or reports the drop. It never waits.
protocol FrameSource: AnyObject {
    // Serial. The sink is called on it, and `keeping` is read and written on it only.
    var queue: DispatchQueue { get }
    var isAvailable: Bool { get }
    // The bundle's capture.timestamps value for this source's frames.
    var timestampSource: String { get }
    var sink: FrameSink? { get set }
    // Non-nil while a take keeps frames.
    var keeping: KeepState? { get set }

    func start()
    func stop()
    func setDepthOverlayEnabled(_ enabled: Bool)
    // Main queue only.
    func makePreviewView() -> UIView
}
