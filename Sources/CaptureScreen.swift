import SwiftUI
import UIKit

struct CaptureScreen: View {
    @ObservedObject private var model = CaptureModel.shared
    @ObservedObject private var link = LinkModel.shared

    var body: some View {
        VStack(spacing: 0) {
            preview
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 4)
            controls
        }
        .background { Theme.ground.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .onAppear { model.resume() }
    }

    private var preview: some View {
        ZStack {
            if model.isSupported {
                SourcePreview(source: model.pipeline.source)
            } else {
                Theme.panel
            }
            if model.showDepth, let overlay = model.depthOverlay {
                // The depth map is in the sensor's landscape orientation, like the camera image the
                // preview rotates and aspect-fills; the same rotation and fill line the two up.
                GeometryReader { geo in
                    Image(decorative: overlay, scale: 1, orientation: .right)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .opacity(0.6)
                .allowsHitTesting(false)
            }
            hud
        }
    }

    private var hud: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip {
                    Dot(color: leftColor)
                    Text(leftText).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let chip = LinkText.chip(link.status) {
                    Chip {
                        Dot(color: Theme.tone(chip.tone))
                        Text(chip.text)
                            .lineLimit(1)
                            .accessibilityIdentifier("link-chip")
                    }
                }
                Chip {
                    Dot(color: model.isRecording ? Theme.red : Theme.dim)
                    ElapsedText(start: model.takeStart)
                }
            }
            if let coaching = model.status.coaching {
                Banner(text: coaching, ground: Theme.coachGround)
            }
            if let error = model.errorText {
                Banner(text: error, ground: Theme.errorGround)
            }
            Spacer(minLength: 0)
            strip
        }
        .padding(12)
    }

    private var strip: some View {
        HStack(spacing: 0) {
            if link.status.paired {
                StripItem(label: "sent", value: String(max(0, model.framesWritten - link.status.waiting)), color: Theme.text)
            } else {
                StripItem(label: "frames", value: String(model.framesWritten), color: Theme.text)
            }
            Spacer(minLength: 6)
            StripItem(label: "tracking", value: model.status.tracking, color: trackingColor)
            Spacer(minLength: 6)
            StripItem(label: "depth", value: model.status.depthOK ? "ok" : "none",
                      color: model.status.depthOK ? Theme.text : Theme.amber)
            if model.framesDropped > 0 {
                Spacer(minLength: 6)
                StripItem(label: "dropped", value: String(model.framesDropped), color: Theme.amber)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.chipGround, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controls: some View {
        HStack {
            DepthToggle(isOn: $model.showDepth)
            Spacer()
            RecordButton(isRecording: model.isRecording) { model.toggleRecording() }
                .disabled(!model.canRecord)
                .opacity(model.canRecord ? 1 : 0.4)
            Spacer()
            Text(String(format: "%.0f fps", model.keptFps))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.muted)
                .frame(width: 56, height: 56)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var leftText: String {
        if !model.isSupported { return "No LiDAR depth" }
        if model.isRecording { return "Recording" }
        if let note = model.note { return note }
        return model.isRunning ? "Ready" : "Paused"
    }

    private var leftColor: Color {
        if !model.isSupported { return Theme.red }
        if model.isRecording { return Theme.red }
        return model.isRunning ? Theme.teal : Theme.dim
    }

    private var trackingColor: Color {
        switch model.status.level {
        case .good: return Theme.text
        case .limited: return Theme.amber
        case .lost: return Theme.red
        }
    }
}

struct SourcePreview: UIViewRepresentable {
    let source: FrameSource

    func makeUIView(context: Context) -> UIView {
        source.makePreviewView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct Chip<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 13))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.chipGround, in: Capsule())
    }
}

struct Dot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct Banner: View {
    let text: String
    let ground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.ground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StripItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(Theme.muted)
            Text(value).foregroundColor(color)
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .lineLimit(1)
    }
}

struct ElapsedText: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            Text(ElapsedText.format(start.map { context.date.timeIntervalSince($0) } ?? 0))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02ld:%02ld", s / 60, s % 60)
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Theme.text, lineWidth: 4)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Theme.red)
                        .frame(width: 58, height: 58)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        isRecording ? "Stop" : "Record"
    }
}

struct DepthToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("Depth")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isOn ? Theme.ground : Theme.muted)
                .frame(width: 56, height: 56)
                .background(isOn ? Theme.teal : Theme.panel, in: Circle())
                .overlay { Circle().stroke(Theme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}
