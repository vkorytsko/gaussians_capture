import ARKit
import CoreVideo
import Foundation
import SceneKit
import UIKit

// The only code that touches ARKit. Every delegate call runs on `queue` and does O(1) work: decide keep
// or skip, copy what a kept frame needs into a pool slot, hand it on, return. It never waits, and no
// ARFrame or ARKit-owned buffer is held past the call. Holding capturedImage alone holds ARKit's pool.
final class ARKitFrameSource: NSObject, FrameSource, ARSessionDelegate {
    static let overlayInterval: TimeInterval = 0.1

    let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.frames", qos: .userInteractive)
    let session = ARSession()
    let isAvailable: Bool
    let timestampSource = "sensor"
    weak var sink: FrameSink?
    var keeping: KeepState?

    private var overlayEnabled = false
    private var lastOverlayTime: TimeInterval = 0
    private var lastStatus = LiveStatus()

    override init() {
        isAvailable = ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        // sceneDepth, not smoothedSceneDepth: the smoothed map lags, and training would learn the lag.
        config.frameSemantics = [.sceneDepth]
        session.delegate = self
        session.run(config)
    }

    func stop() {
        session.pause()
    }

    func setDepthOverlayEnabled(_ enabled: Bool) {
        queue.async {
            self.overlayEnabled = enabled
            self.lastOverlayTime = 0
        }
    }

    func makePreviewView() -> UIView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        return view
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        publishStatus(for: frame)

        if overlayEnabled, let depth = frame.sceneDepth,
           frame.timestamp - lastOverlayTime >= ARKitFrameSource.overlayInterval {
            lastOverlayTime = frame.timestamp
            let image = DepthColormap.image(depth: depth.depthMap, confidence: depth.confidenceMap)
            sink?.frameSource(self, depthOverlay: image)
        }

        guard let keeping = keeping, keeping.claim(frame.timestamp) else { return }
        keep(frame, keeping)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        queue.async { self.sink?.frameSource(self, failed: message) }
    }

    // The world frame may not continue across an interruption, so no more frames are kept for the
    // take in progress, and the sink ends it.
    func sessionWasInterrupted(_ session: ARSession) {
        queue.async {
            self.keeping = nil
            self.sink?.frameSourceInterrupted(self)
        }
    }

    private func keep(_ frame: ARFrame, _ keeping: KeepState) {
        guard let slot = keeping.pool.borrow() else {
            sink?.frameSource(self, dropped: .poolEmpty)
            return
        }
        guard let depth = frame.sceneDepth else {
            slot.release()
            sink?.frameSource(self, dropped: .noDepth)
            return
        }
        guard let captured = ARKitFrameSource.copyFrame(frame, depth: depth, slot: slot) else {
            slot.release()
            sink?.frameSource(self, dropped: .unusable)
            return
        }
        sink?.frameSource(self, captured: captured)
    }

    // Copies everything out of the frame; nil for a frame the bundle cannot carry.
    private static func copyFrame(_ frame: ARFrame, depth: ARDepthData, slot: PoolSlot) -> CapturedFrame? {
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

        // ARConfidenceLevel's raw values (low 0, medium 1, high 2) are the bundle's values as they are.
        var confidenceBytes: Data? = nil
        if let conf = depth.confidenceMap,
           CVPixelBufferGetPixelFormatType(conf) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(conf) == depthWidth,
           CVPixelBufferGetHeight(conf) == depthHeight {
            confidenceBytes = PixelBuffers.packedBytes(conf, bytesPerPixel: 1)
        }

        guard let color = PixelBuffers.duplicate(image) else { return nil }

        let pose = CameraKeys.pose(camera.transform)
        let tracking = trackingKeys(camera.trackingState)

        return CapturedFrame(
            timestamp: frame.timestamp,
            format: FrameFormat(colorWidth: colorWidth, colorHeight: colorHeight,
                                depthWidth: depthWidth, depthHeight: depthHeight),
            color: color,
            slot: slot,
            intrinsics: CameraKeys.intrinsics(camera.intrinsics),
            rotation: pose.rotation,
            center: pose.center,
            depth: depthBytes,
            confidence: confidenceBytes,
            trackingState: tracking.state,
            trackingReason: tracking.reason,
            exposureDurationS: camera.exposureDuration,
            exposureEvOffset: Double(camera.exposureOffset),
            exposureIso: nil)
    }

    // The bundle's tracking.state and tracking.reason tokens.
    static func trackingKeys(_ state: ARCamera.TrackingState) -> (state: String, reason: String?) {
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
        sink?.frameSource(self, status: status)
    }
}
