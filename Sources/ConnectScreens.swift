import AVFoundation
import Combine
import SwiftUI
import UIKit

// Bonjour results for the Connect screen. Browses only while Connect shows. Main queue only.
final class NearbyPCs: ObservableObject {
    @Published private(set) var names: [String] = []
    private let browser = PCBrowser()

    init() {
        browser.onChange = { [weak self] names in self?.names = names }
    }

    func start() {
        browser.start()
    }

    func stop() {
        browser.stop()
    }
}

enum CodeTarget: Hashable {
    case nearby(String)     // a Bonjour instance
    case address            // typed by hand
}

// Shown until a PC is paired: the local-network explanation once, then Connect, then the code.
struct ConnectFlow: View {
    @AppStorage("link.localNetworkExplained") private var explained = false
    @StateObject private var nearby = NearbyPCs()
    @ObservedObject private var link = LinkModel.shared
    @State private var path: [CodeTarget] = []
    @State private var scanning = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if explained {
                    connect
                } else {
                    LocalNetworkExplainer { explained = true }
                }
            }
            .background { Theme.ground.ignoresSafeArea() }
            .navigationDestination(for: CodeTarget.self) { target in
                CodeEntryScreen(target: target)
            }
        }
        .onAppear { if explained { nearby.start() } }
        .onDisappear { nearby.stop() }
        .onChange(of: explained) { _, now in if now { nearby.start() } }
        .sheet(isPresented: $scanning, onDismiss: { CaptureModel.shared.resume() }) {
            QRScannerSheet { scanning = false }
        }
    }

    private var connect: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect to a PC")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("On the PC, open gaussians and click the phone button beside Open.")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.muted)

                WideButton(title: "Scan the QR code", filled: true) {
                    if CaptureModel.shared.releaseCameraForScanner() { scanning = true }
                }
                .disabled(CaptureModel.shared.isRecording)

                VStack(alignment: .leading, spacing: 8) {
                    Text("NEARBY")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.dim)
                    VStack(spacing: 0) {
                        ForEach(nearby.names, id: \.self) { name in
                            Button {
                                path.append(.nearby(name))
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(name).foregroundColor(Theme.text)
                                        Text(name + ".local")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(Theme.muted)
                                    }
                                    Spacer()
                                    Text("\u{203A}").foregroundColor(Theme.muted)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("Looking on this network\u{2026}")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dim)
                }

                WideButton(title: "Enter an address by hand", filled: false) {
                    path.append(.address)
                }

                if case .refused = link.status.phase {
                    let line = LinkText.line(link.status)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.title).foregroundColor(Theme.red)
                        if let detail = line.detail {
                            Text(detail).font(.system(size: 13)).foregroundColor(Theme.muted)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// Before iOS asks for local network access, once.
struct LocalNetworkExplainer: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Local network")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("Gaussians Capture finds your PC on this network and sends it your takes as you record them. "
                 + "Nothing leaves this network.")
                .font(.system(size: 15))
                .foregroundColor(Theme.muted)
            Text("iOS asks next whether to allow local network access. Without it, the app records takes "
                 + "but cannot reach the PC.")
                .font(.system(size: 15))
                .foregroundColor(Theme.muted)
            WideButton(title: "Continue", filled: true, action: onContinue)
            Spacer()
        }
        .padding(20)
    }
}

// The code screen: a nearby PC's name, or an address typed by hand, then six digits on a keypad.
struct CodeEntryScreen: View {
    let target: CodeTarget
    @ObservedObject private var link = LinkModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @State private var address = ""
    @State private var problem: String?
    @State private var submitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("\u{2039} Back") { dismiss() }
                .foregroundColor(Theme.teal)
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Theme.text)
            if target == .address {
                TextField("192.168.1.20 or 192.168.1.20:7420", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundColor(Theme.text)
                    .accessibilityIdentifier("address")
            }
            Text("Enter the code shown in the PC's Connect window.")
                .font(.system(size: 15))
                .foregroundColor(Theme.muted)
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < digits.count ? String(Array(digits)[i]) : "")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.text)
                        .frame(width: 44, height: 56)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(i == digits.count ? Theme.teal : Theme.border, lineWidth: 1)
                        }
                }
            }
            if let problem = problem {
                Text(problem).font(.system(size: 14)).foregroundColor(Theme.red)
            } else if submitted {
                let line = LinkText.line(link.status)
                Text(line.title).font(.system(size: 14)).foregroundColor(Theme.tone(line.tone))
            }
            Spacer(minLength: 8)
            keypad
        }
        .padding(20)
        .background { Theme.ground.ignoresSafeArea() }
        .navigationBarBackButtonHidden(true)
        .onChange(of: link.status.phase) { _, phase in
            guard submitted, case .refused(let reason) = phase else { return }
            digits = ""
            problem = reason == "code" ? "Wrong code. Type it again." : LinkText.line(link.status).detail
        }
    }

    private var title: String {
        switch target {
        case .nearby(let name): return name
        case .address: return "Enter an address"
        }
    }

    private var keypad: some View {
        let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "\u{232B}"]]
        return VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 52)
                        } else {
                            Button {
                                press(key)
                            } label: {
                                Text(key)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(key == "\u{232B}" ? "Delete" : key))
                        }
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        if key == "\u{232B}" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 6 else { return }
        problem = nil
        digits += key
        if digits.count == 6 { submit() }
    }

    private func submit() {
        let linkTarget: LinkTarget
        switch target {
        case .nearby(let name):
            linkTarget = .service(name)
        case .address:
            guard let parsed = LinkAddress.parse(address.trimmingCharacters(in: .whitespaces)) else {
                problem = "Not an address: use host or host:port."
                digits = ""
                return
            }
            linkTarget = .hostPort(parsed.host, parsed.port)
        }
        submitted = true
        LinkClient.shared.pair(target: linkTarget, code: digits)
    }
}

// The QR scanner: the camera, which the frame source gives up while it shows. Checked only on a phone.
struct QRScannerSheet: View {
    let onDone: () -> Void
    @State private var problem: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView { text in
                if LinkClient.shared.pair(url: text) {
                    onDone()
                } else {
                    problem = "Not a pairing code."
                }
            }
            .ignoresSafeArea()
            VStack(spacing: 10) {
                if let problem = problem {
                    Text(problem).foregroundColor(Theme.red)
                }
                WideButton(title: "Cancel", filled: false, action: onDone)
            }
            .padding(20)
        }
        .background(Color.black)
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            let label = UILabel()
            label.text = "No camera"
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            guard let text = code.stringValue, text != lastCode else { continue }
            lastCode = text
            onCode?(text)
            return
        }
    }
}
