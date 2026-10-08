#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

// Debug and test builds only. Plays a synthetic take at 60 frames a second of its own clock, and hands
// its due frames on exactly as the camera source does: keep rule, pool slot, copy, sink.
final class ReplayFrameSource: FrameSource {
    static let launchArgument = "--replay-frames"
    static let ticksPerSecond = 60.0
    static let previewInterval = 0.5
    static let initializingSeconds = 0.5

    let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.replay", qos: .userInteractive)
    let isAvailable = true
    let timestampSource = "synthesized"
    let scene: SyntheticScene
    weak var sink: FrameSink?
    var keeping: KeepState?

    // Everything below is touched on `queue` only.
    private let origin: Double
    private let keepLimit: Int?
    private var delivered = 0
    private var timer: DispatchSourceTimer?
    private var lastTick = -1
    private var lastPreview: Double? = nil
    private var lastStatus: LiveStatus? = nil
    private weak var preview: UIImageView?

    // With `keepLimit`, frames stop being kept once that many have been handed on, as if the take ended.
    init(scene: SyntheticScene = SyntheticScene(), keepLimit: Int? = nil) {
        self.scene = scene
        self.keepLimit = keepLimit
        origin = ProcessInfo.processInfo.systemUptime
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / ReplayFrameSource.ticksPerSecond)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func setDepthOverlayEnabled(_ enabled: Bool) {}

    func makePreviewView() -> UIView {
        let view = UIImageView(frame: .zero)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        queue.async {
            self.preview = view
            self.lastPreview = nil
        }
        return view
    }

    // Timestamps follow the wall clock in whole ticks; a tick the queue was too busy for is skipped,
    // as a camera skips frames.
    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - origin
        let index = Int((elapsed * ReplayFrameSource.ticksPerSecond).rounded(.down))
        guard index > lastTick else { return }
        lastTick = index
        let t = Double(index) / ReplayFrameSource.ticksPerSecond
        let timestamp = origin + t

        publishStatus(at: t)

        var rendered: SyntheticScene.Frame? = nil
        if preview != nil, lastPreview.map({ t - $0 >= ReplayFrameSource.previewInterval }) ?? true {
            lastPreview = t
            let frame = scene.render(at: t)
            rendered = frame
            showPreview(frame)
        }

        guard let keeping = keeping, keepLimit.map({ delivered < $0 }) ?? true, keeping.claim(timestamp) else { return }
        guard let slot = keeping.pool.borrow() else {
            sink?.frameSource(self, dropped: .poolEmpty)
            return
        }
        let frame = rendered ?? scene.render(at: t)
        guard let captured = makeCaptured(frame, timestamp: timestamp, t: t, slot: slot) else {
            slot.release()
            sink?.frameSource(self, dropped: .unusable)
            return
        }
        delivered += 1
        sink?.frameSource(self, captured: captured)
    }

    private func makeCaptured(_ frame: SyntheticScene.Frame, timestamp: Double, t: Double,
                              slot: PoolSlot) -> CapturedFrame? {
        let s = scene
        guard let color = PixelBuffers.make(width: s.colorWidth, height: s.colorHeight,
                                            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
              SyntheticScene.fillYCbCr(color, rgba: frame.rgba, width: s.colorWidth, height: s.colorHeight)
        else { return nil }
        let initializing = t < ReplayFrameSource.initializingSeconds
        return CapturedFrame(
            timestamp: timestamp,
            format: FrameFormat(colorWidth: s.colorWidth, colorHeight: s.colorHeight,
                                depthWidth: s.depthWidth, depthHeight: s.depthHeight),
            color: color,
            slot: slot,
            intrinsics: s.intrinsics,
            rotation: frame.rotation,
            center: frame.center,
            depth: frame.depth,
            confidence: frame.confidence,
            trackingState: initializing ? "limited" : "normal",
            trackingReason: initializing ? "initializing" : nil,
            exposureDurationS: 1.0 / 120.0,
            exposureEvOffset: 0,
            exposureIso: nil)
    }

    private func publishStatus(at t: Double) {
        var status = LiveStatus()
        status.depthOK = true
        if t < ReplayFrameSource.initializingSeconds {
            status.tracking = "initializing"
            status.level = .limited
        } else {
            status.tracking = "normal"
            status.level = .good
        }
        guard status != lastStatus else { return }
        lastStatus = status
        sink?.frameSource(self, status: status)
    }

    private func showPreview(_ frame: SyntheticScene.Frame) {
        guard let image = SyntheticScene.cgImage(rgba: frame.rgba, width: scene.colorWidth,
                                                 height: scene.colorHeight) else { return }
        let view = preview
        DispatchQueue.main.async {
            // The frame is landscape, as a camera's is; the portrait screen turns the view, not the data.
            view?.image = UIImage(cgImage: image, scale: 1, orientation: .right)
        }
    }
}

// A floor and three balls, seen from a camera that circles them at a slow walk. Colour and depth are
// rendered from the same geometry, so depth agrees across frames the way a real take's does. Depth is
// z-depth, at each depth pixel's centre mapped into the colour frame.
struct SyntheticScene {
    struct Frame {
        let rgba: [UInt8]
        let depth: Data             // f32le metres; 0 where no surface is hit
        let confidence: Data        // 2 where a surface is hit, else 0
        let rotation: [Double]      // world-from-camera, row-major
        let center: [Double]
    }

    let colorWidth: Int
    let colorHeight: Int
    let depthWidth: Int
    let depthHeight: Int
    let intrinsics: Intrinsics

    // Sizes keep 4:3; the focal length scales with the width, so every size sees the same view.
    init(colorWidth: Int = 320, colorHeight: Int = 240, depthWidth: Int = 256, depthHeight: Int = 192) {
        self.colorWidth = colorWidth
        self.colorHeight = colorHeight
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        let f = 260 * Double(colorWidth) / 320
        intrinsics = Intrinsics(fx: f, fy: f, cx: Double(colorWidth) / 2, cy: Double(colorHeight) / 2)
    }

    // For wire recordings, which should stay small.
    static let small = SyntheticScene(colorWidth: 160, colorHeight: 120, depthWidth: 64, depthHeight: 48)

    let orbitRadius = 1.6
    let orbitHeight = 1.0
    let orbitRadiansPerSecond = 0.25
    let floorHalfSize = 2.5
    let squareSize = 0.25

    static let balls: [(x: Double, y: Double, z: Double, radius: Double, red: Double, green: Double, blue: Double)] = [
        (0.0, 0.3, 0.0, 0.3, 0.30, 0.75, 0.69),
        (0.55, 0.15, -0.45, 0.15, 0.86, 0.65, 0.26),
        (-0.5, 0.2, 0.35, 0.2, 0.85, 0.33, 0.31),
    ]

    // World-from-camera at scene time t: the camera looks at a point above the middle ball, +y up.
    func pose(at t: Double) -> (rotation: [Double], center: [Double]) {
        let a = orbitRadiansPerSecond * t
        let cx = orbitRadius * cos(a)
        let cy = orbitHeight
        let cz = orbitRadius * sin(a)
        var fx = 0.0 - cx
        var fy = 0.25 - cy
        var fz = 0.0 - cz
        let fl = (fx * fx + fy * fy + fz * fz).squareRoot()
        fx /= fl
        fy /= fl
        fz /= fl
        // right = forward x world up; up = right x forward; the camera looks along its -z.
        let rl = (fz * fz + fx * fx).squareRoot()
        let rx = -fz / rl
        let ry = 0.0
        let rz = fx / rl
        let ux = ry * fz - rz * fy
        let uy = rz * fx - rx * fz
        let uz = rx * fy - ry * fx
        let rotation = [rx, ux, -fx,
                        ry, uy, -fy,
                        rz, uz, -fz]
        return (rotation, [cx, cy, cz])
    }

    func render(at t: Double) -> Frame {
        let camPose = self.pose(at: t)
        let r = camPose.rotation
        let c = camPose.center
        let camera = RayCamera(r0: r[0], r1: r[1], r2: r[2], r3: r[3], r4: r[4], r5: r[5], r6: r[6], r7: r[7], r8: r[8],
                               ox: c[0], oy: c[1], oz: c[2],
                               fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx, cy: intrinsics.cy)

        var rgba = [UInt8](repeating: 255, count: colorWidth * colorHeight * 4)
        for row in 0..<colorHeight {
            for col in 0..<colorWidth {
                let hit = cast(camera, u: Double(col) + 0.5, v: Double(row) + 0.5)
                let shade = color(of: hit)
                let i = (row * colorWidth + col) * 4
                rgba[i] = SyntheticScene.byte(shade.red * 255)
                rgba[i + 1] = SyntheticScene.byte(shade.green * 255)
                rgba[i + 2] = SyntheticScene.byte(shade.blue * 255)
            }
        }

        var depth = [Float](repeating: 0, count: depthWidth * depthHeight)
        var confidence = [UInt8](repeating: 0, count: depthWidth * depthHeight)
        let sx = Double(colorWidth) / Double(depthWidth)
        let sy = Double(colorHeight) / Double(depthHeight)
        for row in 0..<depthHeight {
            for col in 0..<depthWidth {
                let hit = cast(camera, u: (Double(col) + 0.5) * sx, v: (Double(row) + 0.5) * sy)
                if hit.kind >= 0 {
                    let k = row * depthWidth + col
                    depth[k] = Float(hit.s)
                    confidence[k] = 2
                }
            }
        }
        let depthData = depth.withUnsafeBufferPointer { Data(buffer: $0) }
        return Frame(rgba: rgba, depth: depthData, confidence: Data(confidence),
                     rotation: camPose.rotation, center: camPose.center)
    }

    struct RayCamera {
        let r0, r1, r2, r3, r4, r5, r6, r7, r8: Double
        let ox, oy, oz: Double
        let fx, fy, cx, cy: Double
    }

    // kind: -1 nothing, 0 floor, 1...3 a ball. s is the z-depth, since the ray's camera z is -1.
    struct Hit {
        var kind = -1
        var s = Double.infinity
        var x = 0.0
        var y = 0.0
        var z = 0.0
        var dx = 0.0
        var dy = 0.0
        var dz = 0.0
    }

    private func cast(_ cam: RayCamera, u: Double, v: Double) -> Hit {
        let xc = (u - cam.cx) / cam.fx
        let yc = -(v - cam.cy) / cam.fy
        let dx = cam.r0 * xc + cam.r1 * yc - cam.r2
        let dy = cam.r3 * xc + cam.r4 * yc - cam.r5
        let dz = cam.r6 * xc + cam.r7 * yc - cam.r8
        var hit = Hit()
        hit.dx = dx
        hit.dy = dy
        hit.dz = dz
        if dy < -1e-9 {
            let s = -cam.oy / dy
            let px = cam.ox + s * dx
            let pz = cam.oz + s * dz
            if abs(px) <= floorHalfSize && abs(pz) <= floorHalfSize {
                hit.kind = 0
                hit.s = s
            }
        }
        for (n, ball) in SyntheticScene.balls.enumerated() {
            sphere(&hit, cam, n + 1, ball.x, ball.y, ball.z, ball.radius)
        }
        if hit.kind >= 0 {
            hit.x = cam.ox + hit.s * dx
            hit.y = cam.oy + hit.s * dy
            hit.z = cam.oz + hit.s * dz
        }
        return hit
    }

    private func sphere(_ hit: inout Hit, _ cam: RayCamera, _ kind: Int,
                        _ x: Double, _ y: Double, _ z: Double, _ radius: Double) {
        let ocx = cam.ox - x
        let ocy = cam.oy - y
        let ocz = cam.oz - z
        let a = hit.dx * hit.dx + hit.dy * hit.dy + hit.dz * hit.dz
        let b = ocx * hit.dx + ocy * hit.dy + ocz * hit.dz
        let c = ocx * ocx + ocy * ocy + ocz * ocz - radius * radius
        let disc = b * b - a * c
        guard disc >= 0 else { return }
        let s = (-b - disc.squareRoot()) / a
        if s > 1e-6 && s < hit.s {
            hit.kind = kind
            hit.s = s
        }
    }

    private func color(of hit: Hit) -> (red: Double, green: Double, blue: Double) {
        let lx = 0.28, ly = 0.94, lz = 0.19
        switch hit.kind {
        case 0:
            let i = Int((hit.x / squareSize).rounded(.down)) + Int((hit.z / squareSize).rounded(.down))
            let light = i % 2 == 0
            let k = 0.35 + 0.65 * ly
            return light ? (0.78 * k, 0.74 * k, 0.66 * k) : (0.36 * k, 0.34 * k, 0.31 * k)
        case 1, 2, 3:
            let ball = SyntheticScene.balls[hit.kind - 1]
            let nx = (hit.x - ball.x) / ball.radius
            let ny = (hit.y - ball.y) / ball.radius
            let nz = (hit.z - ball.z) / ball.radius
            let k = 0.25 + 0.75 * max(0, nx * lx + ny * ly + nz * lz)
            return (ball.red * k, ball.green * k, ball.blue * k)
        default:
            let up = max(0, min(1, hit.dy * 0.5 + 0.5))
            return (0.10 + 0.08 * up, 0.11 + 0.10 * up, 0.13 + 0.14 * up)
        }
    }

    static func byte(_ x: Double) -> UInt8 {
        UInt8(max(0, min(255, x.rounded())))
    }

    // Full-range BT.601 into a biplanar 4:2:0 buffer; chroma from the top-left pixel of each 2x2 block.
    static func fillYCbCr(_ buffer: CVPixelBuffer, rgba: [UInt8], width: Int, height: Int) -> Bool {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetWidth(buffer) == width,
              CVPixelBufferGetHeight(buffer) == height else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let cPlane = cBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let i = (row * width + col) * 4
                let r = Double(rgba[i])
                let g = Double(rgba[i + 1])
                let b = Double(rgba[i + 2])
                yPlane[row * yStride + col] = byte(0.299 * r + 0.587 * g + 0.114 * b)
                if row % 2 == 0 && col % 2 == 0 {
                    let o = (row / 2) * cStride + col
                    cPlane[o] = byte(128 - 0.168736 * r - 0.331264 * g + 0.5 * b)
                    cPlane[o + 1] = byte(128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
                }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return true
    }

    static func cgImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
