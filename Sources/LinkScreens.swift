import Combine
import SwiftUI
import UIKit

// The link's status for the screens. Main queue only.
final class LinkModel: ObservableObject, LinkObserver {
    static let shared = LinkModel()

    @Published private(set) var status: LinkStatus

    private init() {
        let client = LinkClient.shared
        status = client.queue.sync { client.status() }
        client.observer = self
    }

    func linkChanged(_ status: LinkStatus) {
        self.status = status
    }

    // The connection's start as a wall-clock time.
    var connectedSince: Date? {
        status.connectedSince.map { Date().addingTimeInterval($0 - ProcessInfo.processInfo.systemUptime) }
    }
}

enum AppTab: Hashable {
    case capture, pc
}

// Two tabs, Capture and PC. An unpaired app opens on the PC tab, which shows Connect; a paired one
// opens on Capture.
struct RootView: View {
    @ObservedObject private var link = LinkModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab

    init() {
        _tab = State(initialValue: LinkModel.shared.status.paired ? .capture : .pc)
    }

    var body: some View {
        TabView(selection: $tab) {
            CaptureScreen()
                .tabItem { Label("Capture", systemImage: "camera") }
                .tag(AppTab.capture)
            PCScreen()
                .tabItem { Label("PC", systemImage: "desktopcomputer") }
                .tag(AppTab.pc)
        }
        .tint(Theme.teal)
        .preferredColorScheme(.dark)
        .onAppear { CaptureModel.shared.resume() }
        .onChange(of: link.status.paired) { _, paired in
            if paired { tab = .capture }
        }
        .onChange(of: scenePhase) { _, phase in
            let model = CaptureModel.shared
            if phase == .active {
                model.resume()
            } else {
                model.leftActive()
                if phase == .background {
                    model.suspend()
                }
            }
        }
    }
}

struct PCScreen: View {
    @ObservedObject private var link = LinkModel.shared

    var body: some View {
        Group {
            if link.status.paired {
                PairedPCView()
            } else {
                ConnectFlow()
            }
        }
        .background { Theme.ground.ignoresSafeArea() }
    }
}

// The PC tab, paired: the PC's name and address, the link's state, Disconnect or Connect, and Forget.
struct PairedPCView: View {
    @ObservedObject private var link = LinkModel.shared
    @State private var confirmForget = false

    var body: some View {
        let s = link.status
        let line = LinkText.line(s, since: link.connectedSince)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.pcName ?? "PC")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text(s.address ?? "")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Dot(color: Theme.tone(line.tone))
                    Text(line.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                if let detail = line.detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                }
                if case .waiting(let text) = s.phase, LinkText.isPolicy(text) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundColor(Theme.teal)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 12) {
                if s.phase == .disconnected || isRefused(s.phase) {
                    WideButton(title: "Connect", filled: true) { LinkClient.shared.connect() }
                } else {
                    WideButton(title: "Disconnect", filled: false) { LinkClient.shared.disconnect() }
                }
                WideButton(title: "Forget", filled: false) { confirmForget = true }
            }
            Text("Forget removes this PC from the phone. The PC keeps this phone until you forget it there too.")
                .font(.system(size: 12))
                .foregroundColor(Theme.dim)
            Spacer()
        }
        .padding(20)
        .confirmationDialog("Forget \(s.pcName ?? "this PC")?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { LinkClient.shared.forget() }
        }
    }

    private func isRefused(_ phase: LinkStatus.Phase) -> Bool {
        if case .refused = phase { return true }
        return false
    }
}

struct WideButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(filled ? Theme.ground : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(filled ? Theme.teal : Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}
