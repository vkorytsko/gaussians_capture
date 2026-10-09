import SwiftUI
import UIKit

// The Training tab: what the PC reports of its training, as received. It controls nothing.
struct TrainingScreen: View {
    @ObservedObject private var link = LinkModel.shared

    var body: some View {
        let s = link.status
        let state = TrainingText.state(s)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Training")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.text)
                    if state != .unpaired {
                        Text("on " + (s.pcName ?? "PC"))
                            .font(.system(size: 15))
                            .foregroundColor(Theme.muted)
                    }
                }
                switch state {
                case .unpaired:
                    Text(TrainingText.unpaired)
                        .font(.system(size: 15))
                        .foregroundColor(Theme.muted)
                case .waiting:
                    Text(TrainingText.waiting)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.text)
                    if s.phase != .connected {
                        StateLine(status: s)
                    }
                case .live, .down:
                    if state == .down {
                        StateLine(status: s)
                    }
                    Group {
                        render(s)
                        figures(s)
                    }
                    .opacity(state == .down ? 0.45 : 1)
                }
                Text(TrainingText.footer)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.dim)
            }
            .padding(20)
        }
        .background { Theme.ground.ignoresSafeArea() }
    }

    @ViewBuilder
    private func render(_ s: LinkStatus) -> some View {
        if let thumbnail = s.thumbnail, let image = link.thumbnailImage {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("training-render")
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text(TrainingText.caption(thumbnail, arrivedAt: s.thumbnailAt ?? ProcessInfo.processInfo.systemUptime,
                                              now: ProcessInfo.processInfo.systemUptime))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.muted)
                        .accessibilityIdentifier("training-caption")
                }
            }
        } else {
            Theme.panel
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { Text("No render yet").foregroundColor(Theme.dim) }
        }
    }

    private func figures(_ s: LinkStatus) -> some View {
        VStack(spacing: 0) {
            ForEach(TrainingText.figures(s.progress), id: \.label) { figure in
                HStack {
                    Text(figure.label).foregroundColor(Theme.muted)
                    Spacer()
                    Text(figure.value)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(Theme.text)
                        .accessibilityIdentifier("figure-" + figure.label)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// The PC tab's state line: the link's state and what to do about it.
struct StateLine: View {
    let status: LinkStatus

    var body: some View {
        let line = LinkText.line(status, since: LinkModel.shared.connectedSince)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Dot(color: Theme.tone(line.tone))
                Text(line.title).foregroundColor(Theme.text)
            }
            if let detail = line.detail {
                Text(detail).font(.system(size: 13)).foregroundColor(Theme.muted)
            }
        }
    }
}
