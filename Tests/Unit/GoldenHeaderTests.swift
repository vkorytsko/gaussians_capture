import XCTest
@testable import GaussiansCapture

// golden-headers.bin holds four headers, a manifest and three frames, as the reference writer emits them
// for the values below. Every float needs all 17 significant digits to survive the round trip.
final class GoldenHeaderTests: XCTestCase {
    static let captureId = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    static func manifest() -> ManifestFields {
        ManifestFields(captureId: captureId,
                       startUTC: "2026-09-28T10:11:12.345Z",
                       startTimestampS: 81234.56789012345,
                       fpsNominal: 4.0,
                       timestamps: "sensor",
                       deviceModel: "iPhone16,1",
                       deviceOS: "iOS 26.6.1",
                       producerName: "gd-capture",
                       producerVersion: "0.1",
                       colorWidth: 8,
                       colorHeight: 6,
                       colorEncoding: "jpeg",
                       depthWidth: 4,
                       depthHeight: 3)
    }

    static let rotation: [Double] = [0.1, -0.0, 1.0 / 7.0,
                                     Double.leastNonzeroMagnitude, 1.0, -Double.leastNormalMagnitude,
                                     0.7071067811865476, 1.0.nextUp, -1.0 / 3.0]

    // Frame 1 has no confidence blob and no exposure keys; frame 2 is limited, with a reason.
    static func frame(_ i: Int, rotation: [Double] = GoldenHeaderTests.rotation) -> FrameHeaderFields {
        let full = i != 1
        return FrameHeaderFields(
            captureId: captureId,
            index: i,
            timestampS: 81234.56789012345 + 0.25 * Double(i) + 1.0 / 3.0,
            colorWidth: 8,
            colorHeight: 6,
            colorEncoding: i == 1 ? "png" : "jpeg",
            colorBytes: 37 + 5 * i,
            intrinsics: Intrinsics(fx: 1402.123456789012 + Double(i), fy: 1401.987654321098,
                                   cx: 4.0 / 3.0, cy: 2.9999999999999996),
            rotation: rotation,
            center: [2.0 + Double(i), -1e-17, 123456.78901234567],
            depthWidth: 4,
            depthHeight: 3,
            depthBytes: 4 * 3 * 4,
            confidenceBytes: full ? 4 * 3 : nil,
            trackingState: i == 2 ? "limited" : "normal",
            trackingReason: i == 2 ? "excessiveMotion" : nil,
            exposureDurationS: full ? 1.0 / 120.0 : nil,
            exposureEvOffset: full ? -0.33333333333333331 : nil,
            exposureIso: full ? 250.0 : nil)
    }

    static func written(frame0Rotation: [Double] = GoldenHeaderTests.rotation) -> Data {
        var out = BundleHeaders.manifest(manifest())
        out.append(BundleHeaders.frame(frame(0, rotation: frame0Rotation)))
        out.append(BundleHeaders.frame(frame(1)))
        out.append(BundleHeaders.frame(frame(2)))
        return out
    }

    func golden() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: GoldenHeaderTests.self).url(forResource: "golden-headers", withExtension: "bin"))
        return try Data(contentsOf: url)
    }

    // The line holding the first byte where the two differ, or nil when they are equal.
    static func firstDifferingLine(_ a: Data, _ b: Data) -> String? {
        let x = [UInt8](a)
        let y = [UInt8](b)
        var i = 0
        while i < x.count && i < y.count && x[i] == y[i] { i += 1 }
        if i == x.count && i == y.count { return nil }
        let source = i < x.count ? x : y
        var start = min(i, source.count - 1)
        while start > 0 && source[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < source.count && source[end] != 0x0A { end += 1 }
        return String(decoding: source[start..<end], as: UTF8.self)
    }

    func testHeadersMatchTheReferenceWriterByteForByte() throws {
        let expected = try golden()
        let actual = GoldenHeaderTests.written()
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertNil(GoldenHeaderTests.firstDifferingLine(actual, expected))
        XCTAssertEqual(actual, expected)
    }

    // The failing case: the same values with frame 0's matrix read column-major instead of row-major.
    func testATransposedMatrixFailsTheComparison() throws {
        let r = GoldenHeaderTests.rotation
        let transposed = [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]
        XCTAssertNotEqual(transposed, r)
        let expected = try golden()
        let actual = GoldenHeaderTests.written(frame0Rotation: transposed)
        XCTAssertNotEqual(actual, expected)
        let line = try XCTUnwrap(GoldenHeaderTests.firstDifferingLine(actual, expected))
        XCTAssertTrue(line.hasPrefix("pose.r="), line)
    }
}
