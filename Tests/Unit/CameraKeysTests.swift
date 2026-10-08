import simd
import XCTest
@testable import GaussiansCapture

// A camera turned +90 degrees about +y, at (2, 0, 0): its +x points to world -z, +y to world +y, and it
// looks along world -x, toward the origin. Rows of the rotation: (0 0 1), (0 1 0), (-1 0 0).
final class CameraKeysTests: XCTestCase {
    static let transform = simd_float4x4(columns: (SIMD4<Float>(0, 0, -1, 0),
                                                   SIMD4<Float>(0, 1, 0, 0),
                                                   SIMD4<Float>(1, 0, 0, 0),
                                                   SIMD4<Float>(2, 0, 0, 1)))
    static let rowMajor: [Double] = [0, 0, 1, 0, 1, 0, -1, 0, 0]

    // fx 1400, fy 1401, principal point (960.5, 720.25): exact in Float.
    static let intrinsics = simd_float3x3(columns: (SIMD3<Float>(1400, 0, 0),
                                                    SIMD3<Float>(0, 1401, 0),
                                                    SIMD3<Float>(960.5, 720.25, 1)))

    func poseLines(_ t: simd_float4x4) -> String {
        let pose = CameraKeys.pose(t)
        let header = BundleHeaders.frame(FrameHeaderFields(
            captureId: GoldenHeaderTests.captureId, index: 0, timestampS: 1, colorWidth: 8, colorHeight: 6,
            colorEncoding: "jpeg", colorBytes: 1, intrinsics: Intrinsics(fx: 1, fy: 1, cx: 1, cy: 1),
            rotation: pose.rotation, center: pose.center, depthWidth: 4, depthHeight: 3, depthBytes: 48,
            confidenceBytes: nil, trackingState: "normal", trackingReason: nil,
            exposureDurationS: nil, exposureEvOffset: nil, exposureIso: nil))
        let text = String(decoding: header, as: UTF8.self)
        return text.split(separator: "\n").filter { $0.hasPrefix("pose.") }.joined(separator: "\n")
    }

    func testPoseKeysFromAWorldFromCameraTransform() {
        let pose = CameraKeys.pose(CameraKeysTests.transform)
        XCTAssertEqual(pose.rotation, CameraKeysTests.rowMajor)
        XCTAssertEqual(pose.center, [2, 0, 0])
        XCTAssertEqual(poseLines(CameraKeysTests.transform),
                       "pose.frame=arkit\npose.r=0 0 1 0 1 0 -1 0 0\npose.c=2 0 0")
    }

    // The failing case: the transposed matrix gives other keys.
    func testATransposedTransformGivesOtherKeys() {
        let transposed = CameraKeysTests.transform.transpose
        let pose = CameraKeys.pose(transposed)
        XCTAssertNotEqual(pose.rotation, CameraKeysTests.rowMajor)
        XCTAssertNotEqual(pose.center, [2, 0, 0])
        XCTAssertNotEqual(poseLines(transposed), poseLines(CameraKeysTests.transform))
    }

    func testIntrinsicsFromAColumnMajorMatrix() {
        XCTAssertEqual(CameraKeys.intrinsics(CameraKeysTests.intrinsics),
                       Intrinsics(fx: 1400, fy: 1401, cx: 960.5, cy: 720.25))
    }

    // The failing case: the transposed matrix loses the principal point.
    func testATransposedIntrinsicsMatrixGivesOtherKeys() {
        let k = CameraKeys.intrinsics(CameraKeysTests.intrinsics.transpose)
        XCTAssertNotEqual(k, Intrinsics(fx: 1400, fy: 1401, cx: 960.5, cy: 720.25))
        XCTAssertEqual(k.cx, 0)
        XCTAssertEqual(k.cy, 0)
    }
}
