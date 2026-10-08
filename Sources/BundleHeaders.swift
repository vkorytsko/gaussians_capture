import Foundation

// The capture bundle's record headers, major version 1. Pure: the same values give the same bytes.

struct ManifestFields {
    var captureId: String
    var startUTC: String
    var startTimestampS: Double
    var fpsNominal: Double
    var timestamps: String          // sensor | synthesized
    var deviceModel: String
    var deviceOS: String
    var producerName: String
    var producerVersion: String
    var colorWidth: Int
    var colorHeight: Int
    var colorEncoding: String       // jpeg | png
    var depthWidth: Int
    var depthHeight: Int
}

struct FrameHeaderFields {
    var captureId: String
    var index: Int
    var timestampS: Double
    var colorWidth: Int
    var colorHeight: Int
    var colorEncoding: String
    var colorBytes: Int
    var intrinsics: Intrinsics
    var rotation: [Double]          // world-from-camera, row-major
    var center: [Double]
    var depthWidth: Int
    var depthHeight: Int
    var depthBytes: Int
    var confidenceBytes: Int?       // nil: no confidence blob, and no confidence keys
    var trackingState: String
    var trackingReason: String?
    var exposureDurationS: Double?
    var exposureEvOffset: Double?
    var exposureIso: Double?
}

enum BundleHeaders {
    static let formatVersion = "1.0"

    // Intrinsics are expressed at the colour resolution, which major 1 requires.
    static func manifest(_ m: ManifestFields) -> Data {
        var h = RecordHeader()
        h.add("bundle.version", formatVersion)
        h.add("record.kind", "manifest")
        h.add("capture.id", m.captureId)
        h.add("capture.start_utc", m.startUTC)
        h.add("capture.start_timestamp_s", real: m.startTimestampS)
        h.add("capture.fps_nominal", real: m.fpsNominal)
        h.add("capture.timestamps", m.timestamps)
        h.add("device.model", m.deviceModel)
        h.add("device.os", m.deviceOS)
        h.add("producer.name", m.producerName)
        h.add("producer.version", m.producerVersion)
        h.add("color.width", int: m.colorWidth)
        h.add("color.height", int: m.colorHeight)
        h.add("color.encoding", m.colorEncoding)
        h.add("depth.width", int: m.depthWidth)
        h.add("depth.height", int: m.depthHeight)
        h.add("intrinsics.reference_width", int: m.colorWidth)
        h.add("intrinsics.reference_height", int: m.colorHeight)
        h.add("pose.frame", "arkit")
        return h.bytes
    }

    static func frame(_ f: FrameHeaderFields) -> Data {
        var h = RecordHeader()
        h.add("bundle.version", formatVersion)
        h.add("record.kind", "frame")
        h.add("capture.id", f.captureId)
        h.add("frame.index", int: f.index)
        h.add("frame.timestamp_s", real: f.timestampS)
        h.add("color.width", int: f.colorWidth)
        h.add("color.height", int: f.colorHeight)
        h.add("color.encoding", f.colorEncoding)
        h.add("color.bytes", int: f.colorBytes)
        h.add("intrinsics.fx", real: f.intrinsics.fx)
        h.add("intrinsics.fy", real: f.intrinsics.fy)
        h.add("intrinsics.cx", real: f.intrinsics.cx)
        h.add("intrinsics.cy", real: f.intrinsics.cy)
        h.add("pose.frame", "arkit")
        h.add("pose.r", reals: f.rotation)
        h.add("pose.c", reals: f.center)
        h.add("depth.width", int: f.depthWidth)
        h.add("depth.height", int: f.depthHeight)
        h.add("depth.encoding", "f32le")
        h.add("depth.bytes", int: f.depthBytes)
        if let confidenceBytes = f.confidenceBytes {
            h.add("confidence.encoding", "u8")
            h.add("confidence.bytes", int: confidenceBytes)
        }
        h.add("tracking.state", f.trackingState)
        if let reason = f.trackingReason {
            h.add("tracking.reason", reason)
        }
        if let duration = f.exposureDurationS {
            h.add("exposure.duration_s", real: duration)
        }
        if let offset = f.exposureEvOffset {
            h.add("exposure.ev_offset", real: offset)
        }
        if let iso = f.exposureIso {
            h.add("exposure.iso", real: iso)
        }
        return h.bytes
    }
}

// A header is ASCII key=value lines after the magic line, ended by one empty line that belongs to it.
struct RecordHeader {
    private var text = "# gd-capture-bundle\n"

    mutating func add(_ key: String, _ value: String) {
        text += key + "=" + asciiOnly(value) + "\n"
    }

    mutating func add(_ key: String, int value: Int) {
        add(key, String(value))
    }

    mutating func add(_ key: String, real value: Double) {
        add(key, formatReal(value))
    }

    mutating func add(_ key: String, reals values: [Double]) {
        add(key, values.map { formatReal($0) }.joined(separator: " "))
    }

    var bytes: Data { Data((text + "\n").utf8) }
}

private func formatReal(_ x: Double) -> String {
    String(format: "%.17g", x)
}

private func asciiOnly(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars where u.value >= 0x20 && u.value <= 0x7E {
        out.unicodeScalars.append(u)
    }
    return out
}
