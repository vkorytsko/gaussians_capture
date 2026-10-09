import Foundation

// What the PC tab's state line and the Capture link chip say about the link. Pure.
enum LinkText {
    enum Tone: Equatable {
        case good, waiting, bad
    }

    struct Line: Equatable {
        let title: String
        let detail: String?
        let tone: Tone
    }

    static func isPolicy(_ waiting: String) -> Bool {
        waiting.contains("65570") || waiting.contains("PolicyDenied")
    }

    static func seconds(_ s: Double) -> String {
        String(format: "%.1f s", s)
    }

    // `since` is the connection's start, as a wall-clock time.
    static func line(_ s: LinkStatus, since: Date? = nil) -> Line {
        switch s.phase {
        case .unpaired:
            return Line(title: "Not paired", detail: nil, tone: .bad)
        case .disconnected:
            return Line(title: "Disconnected", detail: "Tap Connect to link again.", tone: .waiting)
        case .connecting:
            return Line(title: "Connecting", detail: nil, tone: .waiting)
        case .reconnecting:
            return Line(title: "Reconnecting", detail: s.waiting > 0 ? "\(s.waiting) frames waiting" : nil, tone: .waiting)
        case .connected:
            if s.takeRefused == "busy" {
                return Line(title: "Connected", detail: "The PC is training another take; this one waits and is offered again.",
                            tone: .waiting)
            }
            if s.captureId != nil && s.waiting > 0 {
                var parts = ["\(s.held) of \(s.committed) sent", "\(s.waiting) waiting"]
                if let b = s.behindS { parts.append("behind " + seconds(b)) }
                return Line(title: "Sending", detail: parts.joined(separator: " \u{00B7} "), tone: .waiting)
            }
            if let since = since {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                return Line(title: "Connected", detail: "since " + f.string(from: since), tone: .good)
            }
            return Line(title: "Connected", detail: nil, tone: .good)
        case .waiting(let text):
            if isPolicy(text) {
                return Line(title: "Local network not allowed",
                            detail: "Allow it in Settings \u{203A} Privacy & Security \u{203A} Local Network.", tone: .bad)
            }
            return Line(title: "Not reachable", detail: "Is the PC on this network, with gaussians open?", tone: .bad)
        case .refused(let reason):
            switch reason {
            case "code":
                return Line(title: "Refused: wrong code", detail: "Type the code again.", tone: .bad)
            case "pairing closed":
                return Line(title: "Refused: pairing closed",
                            detail: "Open the PC's Connection window (Ctrl+C), then try again.", tone: .bad)
            case "token":
                return Line(title: "Refused: this phone was forgotten", detail: "Pair again.", tone: .bad)
            case "busy":
                return Line(title: "Refused: busy",
                            detail: "Another phone is connected, or another take is training. Trying again.", tone: .waiting)
            case "version":
                return Line(title: "Refused: versions differ",
                            detail: s.refusalDetail ?? "This app speaks link version \(LinkFraming.version).", tone: .bad)
            default:
                return Line(title: "Refused: " + reason, detail: s.refusalDetail, tone: .bad)
            }
        }
    }

    // The Capture chip: the PC's name and how far behind it is; nil while unpaired.
    static func chip(_ s: LinkStatus) -> (text: String, tone: Tone)? {
        guard s.phase != .unpaired else { return nil }
        let name = s.pcName ?? "PC"
        switch s.phase {
        case .connected:
            let text = s.behindS.map { name + " \u{00B7} " + seconds($0) } ?? name
            return (text, s.waiting > 0 ? .waiting : .good)
        case .refused, .waiting:
            return (name, .bad)
        default:
            return (name, .waiting)
        }
    }
}
