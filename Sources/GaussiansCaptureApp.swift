import Foundation
import SwiftUI

@main
struct GaussiansCaptureApp: App {
    var body: some Scene {
        WindowGroup { CaptureScreen() }
    }
}

enum FrameSources {
    // A Release build constructs the camera source and nothing else.
    static func make() -> FrameSource {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(ReplayFrameSource.launchArgument) {
            return ReplayFrameSource()
        }
        #endif
        return ARKitFrameSource()
    }
}

enum Theme {
    static let ground = Color(hex: 0x15171A)
    static let panel = Color(hex: 0x1E2226)
    static let border = Color(hex: 0x2C3136)
    static let text = Color(hex: 0xE9E7E2)
    static let muted = Color(hex: 0xA9A9A2)
    static let dim = Color(hex: 0x62666A)
    static let teal = Color(hex: 0x4CC0B0)
    static let amber = Color(hex: 0xDCA542)
    static let red = Color(hex: 0xD9534F)
    static let chipGround = Color(hex: 0x15171A, opacity: 0.8)
    static let coachGround = Color(hex: 0xDCA542, opacity: 0.92)
    static let errorGround = Color(hex: 0xD9534F, opacity: 0.92)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
