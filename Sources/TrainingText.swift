import Foundation

// What the Training tab shows, from what the link received. Pure. Figures are the PC's own text, never
// reformatted; one not yet received reads as a dash.
enum TrainingText {
    static let missing = "\u{2014}"
    static let footer = "Training is run from the PC: it keeps going after capture stops, until Stop there."
    static let waiting = "Waiting for the PC to start training"
    static let unpaired = "Pair with a PC in the PC tab to see its training here."

    struct Figure: Equatable {
        let label: String
        let value: String
    }

    static func figures(_ progress: LinkMessage?) -> [Figure] {
        func value(_ key: String) -> String {
            progress?.value(key) ?? missing
        }
        let psnr = progress?.value("psnr_db").map { $0 + " dB" } ?? missing
        return [
            Figure(label: "iteration", value: value("iteration")),
            Figure(label: "splats", value: value("splats")),
            Figure(label: "frames trained on", value: value("frames")),
            Figure(label: "held-out PSNR", value: psnr),
            Figure(label: "loss", value: value("loss")),
        ]
    }

    // k counts whole seconds since the thumbnail arrived, on the phone's clock.
    static func caption(_ thumbnail: LinkMessage, arrivedAt: Double, now: Double) -> String {
        let k = max(0, Int((now - arrivedAt).rounded(.down)))
        return "the PC's render \u{00B7} iter \(thumbnail.value("iteration") ?? missing) \u{00B7} \(k) s ago"
    }

    enum State: Equatable {
        case unpaired       // a line pointing to the PC tab
        case waiting        // paired, and nothing received from a session yet
        case live           // connected: the figures as they arrive
        case down           // the link is down: the last figures, dimmed, with the link's state line
    }

    static func state(_ s: LinkStatus) -> State {
        if !s.paired { return .unpaired }
        if s.progress == nil && s.thumbnail == nil { return .waiting }
        return s.phase == .connected ? .live : .down
    }
}
