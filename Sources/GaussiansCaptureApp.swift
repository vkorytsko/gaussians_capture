import ARKit
import UIKit
import SwiftUI

@main
struct GaussiansCaptureApp: App {
    var body: some Scene {
        WindowGroup { StatusView() }
    }
}

// P0 hello-world: proves the build, sign and install route, and reports what P1 depends on.
struct StatusView: View {
    private let info = Bundle.main.infoDictionary ?? [:]
    // Persisted across re-signs: a re-sign that keeps this value kept the app's data too.
    @AppStorage("firstLaunch") private var firstLaunch: Double = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    row("Version", info["CFBundleShortVersionString"] as? String ?? "?")
                    row("CI build", info["CFBundleVersion"] as? String ?? "?")
                    row("Bundle id", Bundle.main.bundleIdentifier ?? "?")
                }
                Section("Device") {
                    row("iOS", UIDevice.current.systemVersion)
                    row("First launch", firstLaunchText)
                }
                Section("ARKit (what P1 needs)") {
                    row("World tracking", yesNo(ARWorldTrackingConfiguration.isSupported))
                    row("LiDAR scene depth", yesNo(ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)))
                    row("Smoothed depth", yesNo(ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)))
                    row("Mesh reconstruction", yesNo(ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)))
                }
            }
            .navigationTitle("Gaussians Capture")
        }
        .onAppear { if firstLaunch == 0 { firstLaunch = Date().timeIntervalSince1970 } }
    }

    private var firstLaunchText: String {
        firstLaunch == 0 ? "now" : Date(timeIntervalSince1970: firstLaunch).formatted(date: .abbreviated, time: .shortened)
    }

    private func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).monospaced() }
    }
}
