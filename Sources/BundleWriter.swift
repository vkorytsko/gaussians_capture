import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit

// The capture bundle, directory container, major version 1.

struct TakeInfo {
    let startDate: Date
    let captureId: String
    let startUTC: String
    let fpsNominal: Double
    let timestamps: String
    let deviceModel: String
    let deviceOS: String
    let producerVersion: String

    // Main queue.
    static func make(now: Date, fpsNominal: Double, timestamps: String) -> TakeInfo {
        TakeInfo(startDate: now,
                 captureId: UUID().uuidString.lowercased(),
                 startUTC: ISO8601DateFormatter().string(from: now),
                 fpsNominal: fpsNominal,
                 timestamps: timestamps,
                 deviceModel: machineIdentifier(),
                 deviceOS: "iOS " + UIDevice.current.systemVersion,
                 producerVersion: appVersion())
    }

    // Writer queue only: the name is unique among the directories that queue has created.
    static func newTakeDirectory(for date: Date, in root: URL) throws -> (name: String, url: URL) {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: date)
        var name = base
        var suffix = 2
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = base + "-" + String(suffix)
            suffix += 1
        }
        return (name, root.appendingPathComponent(name, isDirectory: true))
    }

    // e.g. "iPhone16,1"; UIDevice.model only says "iPhone".
    static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func appVersion() -> String {
        let plist = Bundle.main.infoDictionary ?? [:]
        let short = plist["CFBundleShortVersionString"] as? String ?? "0"
        let build = plist["CFBundleVersion"] as? String ?? "0"
        return short + "+" + build
    }
}

enum TakeStorage {
    // Both thresholds are modelled (~1.25 MB per record); set them from the first measured takes.
    static let minFreeBytesToStart: Int64 = 2_000_000_000
    static let minFreeBytesWhileRecording: Int64 = 500_000_000
    static let freeCheckEveryRecords = 50

    static let blobSuffixes = [".color.jpg", ".color.png", ".depth.f32", ".conf.u8"]

    static func documentsURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    // nil when the volume does not say.
    static func freeBytes() -> Int64? {
        guard let documents = try? documentsURL(),
              let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(bytes / 1_000_000) + " MB"
    }

    static func recordStem(_ index: Int) -> String {
        String(format: "%06ld", index)
    }

    // yyyyMMdd-HHmmss, optionally followed by -<n>. Nothing else under the root is a take.
    static func isTakeName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts[0].count == 8,
              parts[1].count == 6 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
    }

    struct SweepResult {
        var takesRemoved = 0
        var filesRemoved = 0
    }

    // Run once per launch, before any take writes. A take killed before its record 0 was committed
    // (no records/000000.txt) is removed whole. In any other take, blobs with no header and .tmp
    // headers go; a take with record 0 committed is never removed, and a record whose <index>.txt
    // exists is never touched.
    static func sweep(root: URL) -> SweepResult {
        let fm = FileManager.default
        var result = SweepResult()
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return result }
        for entry in entries where isTakeName(entry) {
            let take = root.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: take.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let records = take.appendingPathComponent("records", isDirectory: true)
            let firstHeader = records.appendingPathComponent(recordStem(0) + ".txt")
            if !fm.fileExists(atPath: firstHeader.path) {
                if remove(take) { result.takesRemoved += 1 }
                continue
            }
            if let names = try? fm.contentsOfDirectory(atPath: take.path) {
                for name in names where name.hasSuffix(".tmp") {
                    if remove(take.appendingPathComponent(name)) { result.filesRemoved += 1 }
                }
            }
            guard let names = try? fm.contentsOfDirectory(atPath: records.path) else { continue }
            let headers = Set(names.filter { $0.hasSuffix(".txt") })
            for name in names {
                let url = records.appendingPathComponent(name)
                if name.hasSuffix(".tmp") {
                    if remove(url) { result.filesRemoved += 1 }
                    continue
                }
                guard blobSuffixes.contains(where: { name.hasSuffix($0) }) else { continue }
                let stem = name.split(separator: ".").first.map { String($0) } ?? name
                if !headers.contains(stem + ".txt") {
                    if remove(url) { result.filesRemoved += 1 }
                }
            }
        }
        return result
    }

    private static func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

struct TakeResult {
    let captureId: String
    let name: String?               // nil when no record was written
    let framesWritten: Int
    let dropped: Int
    let discarded: Int              // queued when the app reached the background, never encoded
    let failure: String?
}

// The GPU may be used only while the app is in the foreground. close() is called as the app enters
// the background and waits for an encode in progress, so once it returns no encode runs until open().
final class ForegroundGate {
    private let lock = NSLock()
    private var isOpen = true

    func open() {
        set(true)
    }

    func close() {
        set(false)
    }

    // Runs body under the lock when open; returns false, without running it, when closed.
    func runIfOpen(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        body()
        return true
    }

    private func set(_ value: Bool) {
        lock.lock()
        isOpen = value
        lock.unlock()
    }
}

struct WriterError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// Used on one serial queue only.
final class BundleWriter {
    static let producerName = "gd-capture"
    static let jpegQuality = 0.9

    let info: TakeInfo
    let root: URL
    private let gate: ForegroundGate
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var directory: URL?
    private var recordsURL: URL?
    private var name: String?
    private var manifestWritten = false
    private(set) var framesWritten = 0
    private(set) var discarded = 0
    private(set) var failure: String?

    init(info: TakeInfo, gate: ForegroundGate, root: URL) {
        self.info = info
        self.gate = gate
        self.root = root
    }

    // frame.index is assigned here, at write time, so a dropped frame never leaves a gap. Blobs first,
    // then the header to <index>.txt.tmp, renamed: the rename commits the record. After a failure, a
    // low-space stop or a discarded record nothing more is written, so the records on disk stay
    // contiguous from 0.
    func write(_ frame: CapturedFrame) {
        guard failure == nil else { return }
        if discarded > 0 {
            discarded += 1
            return
        }
        let index = framesWritten
        do {
            let image = CIImage(cvPixelBuffer: frame.color)
            let options: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: BundleWriter.jpegQuality
            ]
            var encoded: Data? = nil
            let ran = gate.runIfOpen {
                encoded = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
            }
            guard ran else {
                discarded = 1
                return
            }
            guard let jpeg = encoded else {
                throw WriterError(index == 0
                    ? "JPEG encoding failed on the first frame; nothing was saved"
                    : "JPEG encoding failed at frame \(index); frames 0 to \(index - 1) are saved")
            }
            let records = try recordsDirectory()
            if !manifestWritten {
                let manifest = records.deletingLastPathComponent().appendingPathComponent("manifest.txt")
                try commit(manifestHeader(first: frame), to: manifest)
                manifestWritten = true
            }
            let stem = TakeStorage.recordStem(index)
            try jpeg.write(to: records.appendingPathComponent(stem + ".color.jpg"))
            try frame.depth.write(to: records.appendingPathComponent(stem + ".depth.f32"))
            if let confidence = frame.confidence {
                try confidence.write(to: records.appendingPathComponent(stem + ".conf.u8"))
            }
            try commit(frameHeader(frame, index: index, colorBytes: jpeg.count),
                       to: records.appendingPathComponent(stem + ".txt"))
            framesWritten += 1
            if framesWritten % TakeStorage.freeCheckEveryRecords == 0,
               let free = TakeStorage.freeBytes(),
               free < TakeStorage.minFreeBytesWhileRecording {
                failure = "storage low (" + TakeStorage.megabytes(free) + " free); the take is saved"
            }
        } catch let error as WriterError {
            failure = error.message
        } catch {
            failure = "record \(index): \(error.localizedDescription)"
        }
    }

    func finish(dropped: Int) -> TakeResult {
        if framesWritten == 0, let directory = directory {
            try? FileManager.default.removeItem(at: directory)
        }
        return TakeResult(captureId: info.captureId, name: framesWritten > 0 ? name : nil,
                          framesWritten: framesWritten, dropped: dropped, discarded: discarded,
                          failure: failure)
    }

    // The take directory is created with record 0, on the writer queue, so the launch sweep queued
    // ahead of every take never sees one in progress.
    private func recordsDirectory() throws -> URL {
        if let records = recordsURL { return records }
        let place = try TakeInfo.newTakeDirectory(for: info.startDate, in: root)
        directory = place.url
        name = place.name
        let records = place.url.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        recordsURL = records
        return records
    }

    private func commit(_ header: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        try header.write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    // Written with record 0: the start timestamp and the nominal sizes are record 0's.
    private func manifestHeader(first frame: CapturedFrame) -> Data {
        BundleHeaders.manifest(ManifestFields(
            captureId: info.captureId,
            startUTC: info.startUTC,
            startTimestampS: frame.timestamp,
            fpsNominal: info.fpsNominal,
            timestamps: info.timestamps,
            deviceModel: info.deviceModel,
            deviceOS: info.deviceOS,
            producerName: BundleWriter.producerName,
            producerVersion: info.producerVersion,
            colorWidth: frame.format.colorWidth,
            colorHeight: frame.format.colorHeight,
            colorEncoding: "jpeg",
            depthWidth: frame.format.depthWidth,
            depthHeight: frame.format.depthHeight))
    }

    private func frameHeader(_ frame: CapturedFrame, index: Int, colorBytes: Int) -> Data {
        BundleHeaders.frame(FrameHeaderFields(
            captureId: info.captureId,
            index: index,
            timestampS: frame.timestamp,
            colorWidth: frame.format.colorWidth,
            colorHeight: frame.format.colorHeight,
            colorEncoding: "jpeg",
            colorBytes: colorBytes,
            intrinsics: frame.intrinsics,
            rotation: frame.rotation,
            center: frame.center,
            depthWidth: frame.format.depthWidth,
            depthHeight: frame.format.depthHeight,
            depthBytes: frame.depth.count,
            confidenceBytes: frame.confidence?.count,
            trackingState: frame.trackingState,
            trackingReason: frame.trackingReason,
            exposureDurationS: frame.exposureDurationS,
            exposureEvOffset: frame.exposureEvOffset,
            exposureIso: frame.exposureIso))
    }
}
