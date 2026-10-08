import CoreGraphics
import Foundation
import UIKit

// Every call arrives on the main queue.
protocol CaptureObserver: AnyObject {
    func apply(_ status: LiveStatus)
    func showOverlay(_ image: CGImage?)
    func takeProgress(takeID: String, framesWritten: Int, failure: String?)
    func takeDropped(takeID: String, count: Int)
    func takeEnded(_ result: TakeResult)
    func sweepFinished(_ swept: TakeStorage.SweepResult)
    func sessionInterrupted()
    func sessionFailed(_ message: String)
}

// State of the take in progress; touched on the source's queue only.
private final class TakeState {
    let writer: BundleWriter
    var dropped = 0
    var format: FrameFormat?

    init(writer: BundleWriter) {
        self.writer = writer
    }
}

// Main queue only. Lets the writer finish a take's queued records if the app leaves the foreground
// meanwhile; ended exactly once, by the take's end or by the system's expiry.
private final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            self.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// Threading: the source calls this sink on its own queue, which owns `take`. Kept frames go to
// writeQueue for JPEG encoding and file writes. The observer is reached only through the main queue.
// The app makes one pipeline per process, so one writer queue: the launch sweep and every take's
// records are serialised on it.
final class CapturePipeline: FrameSink {
    // Colour copies a take may hold at once; a due frame with none free is dropped.
    static let maxPendingFrames = 3

    let source: FrameSource
    let root: URL
    let foregroundGate = ForegroundGate()
    // Writer queue only.
    let encoder = JPEGEncoder()
    let writeQueue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.writer", qos: .userInitiated)
    weak var observer: CaptureObserver?
    // Told of each committed record and of each take's end, on the writer queue. Set once, at launch.
    weak var commitListener: TakeCommitListener?

    private var take: TakeState?
    private var observers: [NSObjectProtocol] = []

    init(source: FrameSource, root: URL) {
        self.source = source
        self.root = root
        source.sink = self

        // The first work on the writer queue, so it runs before any take can write. The warm-up goes
        // through the foreground gate, so it never encodes in the background.
        writeQueue.async {
            let swept = TakeStorage.sweep(root: root)
            if swept.takesRemoved > 0 || swept.filesRemoved > 0 {
                DispatchQueue.main.async { self.observer?.sweepFinished(swept) }
            }
            _ = self.foregroundGate.runIfOpen { self.encoder.warmUp() }
        }

        // queue nil: the gate closes synchronously inside the transition to the background.
        let gate = foregroundGate
        let center = NotificationCenter.default
        let closing = [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification]
        let opening = [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification]
        for name in closing {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in gate.close() })
        }
        for name in opening {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in gate.open() })
        }
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // Frames are kept from the next due one. The returned state is the take's, for inspection only.
    @discardableResult
    func beginTake(_ info: TakeInfo, poolCapacity: Int = CapturePipeline.maxPendingFrames) -> KeepState {
        let writer = BundleWriter(info: info, gate: foregroundGate, root: root, encoder: encoder)
        let keeping = KeepState(pool: FramePool(capacity: poolCapacity))
        source.queue.async {
            self.take = TakeState(writer: writer)
            self.source.keeping = keeping
        }
        return keeping
    }

    // Called on main. No frame is kept after this; the writer finishes after every record already
    // queued, because writeQueue is serial. `completion` runs on main with the take's result.
    func endTake(completion: ((TakeResult) -> Void)? = nil) {
        let activity = BackgroundActivity(name: "Finish take")
        source.queue.async {
            self.source.keeping = nil
            guard let take = self.take else {
                DispatchQueue.main.async { activity.end() }
                return
            }
            self.take = nil
            let dropped = take.dropped
            self.writeQueue.async {
                let directory = take.writer.takeDirectory
                let result = take.writer.finish(dropped: dropped)
                if let directory = directory, result.framesWritten > 0 {
                    self.commitListener?.takeEnded(directory: directory, captureId: result.captureId,
                                                   last: result.framesWritten - 1)
                }
                DispatchQueue.main.async {
                    self.observer?.takeEnded(result)
                    completion?(result)
                    activity.end()
                }
            }
        }
    }

    // FrameSink, on the source's queue.

    func frameSource(_ source: FrameSource, captured frame: CapturedFrame) {
        guard let take = take else {
            frame.slot.release()
            return
        }
        guard take.format == nil || take.format == frame.format else {
            frame.slot.release()
            countDrop(take)
            return
        }
        take.format = frame.format
        let writer = take.writer
        writeQueue.async {
            let before = writer.framesWritten
            writer.write(frame)
            if writer.framesWritten > before, let directory = writer.takeDirectory {
                self.commitListener?.takeCommitted(directory: directory, captureId: writer.info.captureId,
                                                   index: writer.framesWritten - 1)
            }
            frame.slot.release()
            let written = writer.framesWritten
            let failure = writer.failure
            DispatchQueue.main.async {
                self.observer?.takeProgress(takeID: writer.info.captureId, framesWritten: written, failure: failure)
            }
        }
    }

    func frameSource(_ source: FrameSource, dropped reason: DropReason) {
        guard let take = take else { return }
        countDrop(take)
    }

    func frameSource(_ source: FrameSource, status: LiveStatus) {
        DispatchQueue.main.async { self.observer?.apply(status) }
    }

    func frameSource(_ source: FrameSource, depthOverlay: CGImage?) {
        DispatchQueue.main.async { self.observer?.showOverlay(depthOverlay) }
    }

    func frameSourceInterrupted(_ source: FrameSource) {
        DispatchQueue.main.async { self.observer?.sessionInterrupted() }
    }

    func frameSource(_ source: FrameSource, failed message: String) {
        DispatchQueue.main.async { self.observer?.sessionFailed(message) }
    }

    private func countDrop(_ take: TakeState) {
        take.dropped += 1
        let id = take.writer.info.captureId
        let count = take.dropped
        DispatchQueue.main.async { self.observer?.takeDropped(takeID: id, count: count) }
    }
}
