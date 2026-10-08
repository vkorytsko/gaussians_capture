import Combine
import CoreGraphics
import SwiftUI
import UIKit

// The screen's state. Every method here runs on the main queue. One per process, like the pipeline,
// so a scene recreated by the system finds the same take state.
final class CaptureModel: ObservableObject, CaptureObserver {
    static let shared = CaptureModel()

    @Published private(set) var status = LiveStatus()
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var takeStart: Date? = nil
    @Published private(set) var framesWritten = 0
    @Published private(set) var framesDropped = 0
    @Published private(set) var note: String? = nil
    @Published private(set) var errorText: String? = nil
    @Published private(set) var depthOverlay: CGImage? = nil
    @Published var showDepth = false {
        didSet {
            pipeline.source.setDepthOverlayEnabled(showDepth)
            if !showDepth { depthOverlay = nil }
        }
    }

    let isSupported: Bool
    let pipeline: CapturePipeline
    let keptFps = KeepRule.framesPerSecond
    private var currentTakeID: String? = nil

    var canRecord: Bool { isSupported && isRunning }

    private init() {
        let root = (try? TakeStorage.documentsURL())
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        let pipeline = CapturePipeline(source: FrameSources.make(), root: root)
        self.pipeline = pipeline
        isSupported = pipeline.source.isAvailable
        pipeline.observer = self
        pipeline.commitListener = LinkClient.shared
    }

    func resume() {
        LinkClient.shared.setForeground(true)
        guard isSupported, !isRunning else { return }
        pipeline.source.start()
        isRunning = true
    }

    // The app is in the background: the link closes too.
    func suspend() {
        stopRecording()
        LinkClient.shared.setForeground(false)
        guard isRunning else { return }
        pipeline.source.stop()
        isRunning = false
    }

    // Any phase other than .active: no more frames are kept, and the take ends at the records already
    // queued.
    func leftActive() {
        stopRecording()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard canRecord, !isRecording else { return }
        if let free = TakeStorage.freeBytes(), free < TakeStorage.minFreeBytesToStart {
            errorText = "Not enough space: " + TakeStorage.megabytes(free) + " free, a take needs "
                + TakeStorage.megabytes(TakeStorage.minFreeBytesToStart)
            return
        }
        let now = Date()
        let info = TakeInfo.make(now: now, fpsNominal: keptFps, timestamps: pipeline.source.timestampSource)
        currentTakeID = info.captureId
        framesWritten = 0
        framesDropped = 0
        note = nil
        errorText = nil
        takeStart = now
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        pipeline.beginTake(info)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        takeStart = nil
        note = "Saving"
        UIApplication.shared.isIdleTimerDisabled = false
        pipeline.endTake()
    }

    // CaptureObserver, on the main queue.

    func apply(_ newStatus: LiveStatus) {
        status = newStatus
    }

    func showOverlay(_ image: CGImage?) {
        if showDepth { depthOverlay = image }
    }

    func takeProgress(takeID: String, framesWritten written: Int, failure: String?) {
        guard takeID == currentTakeID else { return }
        framesWritten = written
        if let failure = failure, isRecording {
            errorText = "Recording stopped: " + failure
            stopRecording()
        }
    }

    func takeDropped(takeID: String, count: Int) {
        guard takeID == currentTakeID else { return }
        framesDropped = count
    }

    func takeEnded(_ result: TakeResult) {
        guard result.captureId == currentTakeID else { return }
        framesWritten = result.framesWritten
        if result.framesWritten == 0 {
            note = "Nothing recorded"
        } else {
            note = "Saved \u{00B7} \(result.framesWritten) frames"
        }
        if let failure = result.failure {
            errorText = "Recording stopped: " + failure
        } else if result.discarded > 0 {
            errorText = "The app went to the background: the last " + String(result.discarded)
                + " queued frames were not saved"
        }
    }

    func sweepFinished(_ swept: TakeStorage.SweepResult) {
        guard !isRecording, note == nil else { return }
        var parts: [String] = []
        if swept.takesRemoved > 0 {
            parts.append(String(swept.takesRemoved) + " empty take" + (swept.takesRemoved == 1 ? "" : "s"))
        }
        if swept.filesRemoved > 0 {
            parts.append(String(swept.filesRemoved) + " unfinished file" + (swept.filesRemoved == 1 ? "" : "s"))
        }
        guard !parts.isEmpty else { return }
        note = "Cleaned " + parts.joined(separator: ", ")
    }

    func sessionInterrupted() {
        guard isRecording else { return }
        stopRecording()
        errorText = "Recording stopped: the camera was interrupted. Press record for a new take."
    }

    func sessionFailed(_ message: String) {
        stopRecording()
        isRunning = false
        errorText = "Camera: " + message
    }
}
