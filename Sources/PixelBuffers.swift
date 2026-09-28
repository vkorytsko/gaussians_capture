import CoreGraphics
import CoreVideo
import Foundation

enum PixelBuffers {
    // A private copy, so ARKit's pooled buffer goes back to the pool before the JPEG is encoded.
    static func duplicate(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         CVPixelBufferGetPixelFormatType(source),
                                         attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let copy = created else { return nil }
        // Carries the YCbCr matrix and colour tags that Core Image needs to convert to RGB.
        CVBufferPropagateAttachments(source, copy)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
                copyRows(src: src, srcStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                         dst: dst, dstStride: CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                         rows: CVPixelBufferGetHeightOfPlane(source, plane))
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(copy) else { return nil }
            copyRows(src: src, srcStride: CVPixelBufferGetBytesPerRow(source),
                     dst: dst, dstStride: CVPixelBufferGetBytesPerRow(copy),
                     rows: height)
        }
        return copy
    }

    // Row-major, top-down, no row padding: the bundle's raw blob layout.
    static func packedBytes(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * bytesPerPixel
        guard rowStride >= rowBytes else { return nil }
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Void in
            guard let dst = out.baseAddress else { return }
            for row in 0..<height {
                memcpy(dst + row * rowBytes, base + row * rowStride, rowBytes)
            }
        }
        return data
    }

    private static func copyRows(src: UnsafeMutableRawPointer, srcStride: Int,
                                 dst: UnsafeMutableRawPointer, dstStride: Int, rows: Int) {
        let count = min(srcStride, dstStride)
        for row in 0..<rows {
            memcpy(dst + row * dstStride, src + row * srcStride, count)
        }
    }
}

// The Depth overlay: near is red, far is violet; no return and low confidence are transparent.
enum DepthColormap {
    static let nearMetres: Float = 0.3
    static let farMetres: Float = 5.0

    private static let palette: [(UInt8, UInt8, UInt8)] = (0..<256).map { i -> (UInt8, UInt8, UInt8) in
        DepthColormap.hueToRGB(Double(i) / 255.0 * 0.75)
    }

    static func image(depth: CVPixelBuffer, confidence: CVPixelBuffer?) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let conf = confidence { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer { if let conf = confidence { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depth)
        var confBase: UnsafeMutableRawPointer? = nil
        var confStride = 0
        if let conf = confidence,
           CVPixelBufferGetPixelFormatType(conf) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(conf) == width, CVPixelBufferGetHeight(conf) == height {
            confBase = CVPixelBufferGetBaseAddress(conf)
            confStride = CVPixelBufferGetBytesPerRow(conf)
        }

        let span = farMetres - nearMetres
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = (depthBase + y * depthStride).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let d = row[x]
                if !d.isFinite || d <= 0 { continue }
                if let cb = confBase, cb.load(fromByteOffset: y * confStride + x, as: UInt8.self) == 0 { continue }
                let t = min(max((d - nearMetres) / span, 0), 1)
                let color = palette[Int(t * 255)]
                let i = (y * width + x) * 4
                rgba[i] = color.0
                rgba[i + 1] = color.1
                rgba[i + 2] = color.2
                rgba[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func hueToRGB(_ hue: Double) -> (UInt8, UInt8, UInt8) {
        let x = hue * 6
        let sector = Int(x.rounded(.down))
        let f = x - Double(sector)
        let rgb: (Double, Double, Double)
        switch sector {
        case 0: rgb = (1, f, 0)
        case 1: rgb = (1 - f, 1, 0)
        case 2: rgb = (0, 1, f)
        case 3: rgb = (0, 1 - f, 1)
        case 4: rgb = (f, 0, 1)
        default: rgb = (1, 0, 1 - f)
        }
        return (UInt8(rgb.0 * 255), UInt8(rgb.1 * 255), UInt8(rgb.2 * 255))
    }
}
