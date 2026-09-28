import ARKit
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

enum TrackingText {
    // The bundle's tracking.state and tracking.reason tokens.
    static func keys(_ state: ARCamera.TrackingState) -> (state: String, reason: String?) {
        switch state {
        case .normal:
            return ("normal", nil)
        case .notAvailable:
            return ("notAvailable", nil)
        case .limited(let reason):
            switch reason {
            case .initializing: return ("limited", "initializing")
            case .excessiveMotion: return ("limited", "excessiveMotion")
            case .insufficientFeatures: return ("limited", "insufficientFeatures")
            case .relocalizing: return ("limited", "relocalizing")
            @unknown default: return ("limited", "other")
            }
        @unknown default:
            return ("unknown", nil)
        }
    }
}

extension FrameSnapshot {
    // Copies everything out of the frame; returns nil for a frame the bundle cannot carry.
    static func capture(_ frame: ARFrame, depth: ARDepthData) -> FrameSnapshot? {
        let camera = frame.camera
        let image = frame.capturedImage
        let colorWidth = CVPixelBufferGetWidth(image)
        let colorHeight = CVPixelBufferGetHeight(image)
        // ARKit's intrinsics are at imageResolution; the stored size must be the same.
        guard colorWidth == Int(camera.imageResolution.width),
              colorHeight == Int(camera.imageResolution.height) else { return nil }

        let depthMap = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              let depthBytes = PixelBuffers.packedBytes(depthMap, bytesPerPixel: 4) else { return nil }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        var confidenceBytes: Data? = nil
        if let conf = depth.confidenceMap,
           CVPixelBufferGetPixelFormatType(conf) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(conf) == depthWidth,
           CVPixelBufferGetHeight(conf) == depthHeight {
            confidenceBytes = PixelBuffers.packedBytes(conf, bytesPerPixel: 1)
        }

        guard let color = PixelBuffers.duplicate(image) else { return nil }

        // simd matrices subscript as [column][row].
        let k = camera.intrinsics
        let t = camera.transform
        var rotation: [Double] = []
        for row in 0..<3 {
            for col in 0..<3 {
                rotation.append(Double(t[col][row]))
            }
        }
        let center = [Double(t[3][0]), Double(t[3][1]), Double(t[3][2])]
        let tracking = TrackingText.keys(camera.trackingState)

        return FrameSnapshot(
            timestamp: frame.timestamp,
            format: FrameFormat(colorWidth: colorWidth, colorHeight: colorHeight,
                                depthWidth: depthWidth, depthHeight: depthHeight),
            color: color,
            fx: Double(k[0][0]),
            fy: Double(k[1][1]),
            cx: Double(k[2][0]),
            cy: Double(k[2][1]),
            rotation: rotation,
            center: center,
            depth: depthBytes,
            confidence: confidenceBytes,
            trackingState: tracking.state,
            trackingReason: tracking.reason,
            exposureDurationS: camera.exposureDuration,
            exposureEvOffset: Double(camera.exposureOffset))
    }
}

// State of the take in progress; touched on the frame queue only.
private final class Take {
    let writer: BundleWriter
    var lastKeptTimestamp: TimeInterval? = nil
    var pending = 0
    var dropped = 0
    var format: FrameFormat?
    var interrupted = false

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

// Threading: ARKit calls the delegate on frameQueue, which owns every private var below. Kept frames
// are copied there and handed to writeQueue for JPEG encoding and file writes. The model is reached
// only through DispatchQueue.main. There is one engine per process, so one writer queue: the launch
// sweep and every take's records are serialised on it.
final class CaptureEngine: NSObject, ARSessionDelegate {
    static let shared = CaptureEngine()

    // The one rate setting. A frame is due when its timestamp is at least 1/rate minus the slack after
    // the last due one; timestamps, not a frame count, because ARKit itself may skip frames.
    static let keptFramesPerSecond = 4.0
    static let keepSlack: TimeInterval = 0.002
    static let maxPendingWrites = 3
    static let overlayInterval: TimeInterval = 0.1

    let session = ARSession()
    let foregroundGate = ForegroundGate()
    weak var model: CaptureModel?

    private let frameQueue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.frames", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.writer", qos: .userInitiated)

    private var take: Take?
    private var overlayEnabled = false
    private var lastOverlayTime: TimeInterval = 0
    private var lastStatus = LiveStatus()
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = frameQueue

        // The first work on the writer queue, once per launch, so it runs before any take can write.
        writeQueue.async {
            let swept = TakeStorage.sweep()
            if swept.takesRemoved > 0 || swept.filesRemoved > 0 {
                DispatchQueue.main.async { self.model?.sweepFinished(swept) }
            }
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

    func run() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.delegate = self
        session.run(config)
    }

    func pause() {
        session.pause()
    }

    func setOverlayEnabled(_ enabled: Bool) {
        frameQueue.async {
            self.overlayEnabled = enabled
            self.lastOverlayTime = 0
        }
    }

    func beginTake(_ writer: BundleWriter) {
        frameQueue.async {
            self.take = Take(writer: writer)
        }
    }

    // Called on main. The writer finishes after every record already queued, because writeQueue is
    // serial.
    func endTake() {
        let activity = BackgroundActivity(name: "Finish take")
        frameQueue.async {
            guard let take = self.take else {
                DispatchQueue.main.async { activity.end() }
                return
            }
            self.take = nil
            let dropped = take.dropped
            self.writeQueue.async {
                let result = take.writer.finish(dropped: dropped)
                DispatchQueue.main.async {
                    self.model?.takeEnded(result)
                    activity.end()
                }
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        publishStatus(for: frame)

        if overlayEnabled, let depth = frame.sceneDepth,
           frame.timestamp - lastOverlayTime >= CaptureEngine.overlayInterval {
            lastOverlayTime = frame.timestamp
            let image = DepthColormap.image(depth: depth.depthMap, confidence: depth.confidenceMap)
            DispatchQueue.main.async { self.model?.showOverlay(image) }
        }

        guard let take = take, !take.interrupted else { return }
        if let last = take.lastKeptTimestamp,
           frame.timestamp < last + 1.0 / CaptureEngine.keptFramesPerSecond - CaptureEngine.keepSlack {
            return
        }
        // A due frame is kept or counted as dropped; either way the next one is a full interval later.
        take.lastKeptTimestamp = frame.timestamp
        keep(frame, in: take)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.model?.sessionFailed(message) }
    }

    // The world frame may not continue across an interruption, so the take in progress keeps no more
    // frames and the model ends it. A new take starts only when the user presses record again.
    func sessionWasInterrupted(_ session: ARSession) {
        frameQueue.async { self.take?.interrupted = true }
        DispatchQueue.main.async { self.model?.sessionInterrupted() }
    }

    // Never blocks: a due frame the writer has no room for is dropped and counted.
    private func keep(_ frame: ARFrame, in take: Take) {
        guard take.pending < CaptureEngine.maxPendingWrites,
              let depth = frame.sceneDepth,
              let snapshot = FrameSnapshot.capture(frame, depth: depth),
              take.format == nil || take.format == snapshot.format else {
            take.dropped += 1
            let id = take.writer.info.captureId
            let count = take.dropped
            DispatchQueue.main.async { self.model?.takeDropped(takeID: id, count: count) }
            return
        }
        take.format = snapshot.format
        take.pending += 1
        let writer = take.writer
        writeQueue.async {
            writer.write(snapshot)
            let written = writer.framesWritten
            let failure = writer.failure
            self.frameQueue.async { take.pending -= 1 }
            DispatchQueue.main.async {
                self.model?.takeProgress(takeID: writer.info.captureId, framesWritten: written, failure: failure)
            }
        }
    }

    private func publishStatus(for frame: ARFrame) {
        var status = LiveStatus()
        status.depthOK = frame.sceneDepth != nil
        switch frame.camera.trackingState {
        case .normal:
            status.tracking = "normal"
            status.level = .good
        case .notAvailable:
            status.tracking = "lost"
            status.level = .lost
            status.coaching = "Tracking lost"
        case .limited(let reason):
            status.tracking = "limited"
            status.level = .limited
            switch reason {
            case .initializing:
                status.tracking = "initializing"
            case .excessiveMotion:
                status.coaching = "Move slower"
            case .insufficientFeatures:
                status.coaching = "Not enough detail"
            case .relocalizing:
                status.tracking = "relocalizing"
                status.level = .lost
                status.coaching = "Tracking lost"
            @unknown default:
                break
            }
        @unknown default:
            status.tracking = "unknown"
            status.level = .limited
        }
        guard status != lastStatus else { return }
        lastStatus = status
        let published = status
        DispatchQueue.main.async { self.model?.apply(published) }
    }
}
