import XCTest

// Screenshots of the Capture screen fed by synthetic frames: ready, recording, saved.
final class CaptureScreenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureScreenWithReplayFrames() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--replay-frames"]
        app.launch()

        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 60))
        XCTAssertTrue(record.isEnabled)
        Thread.sleep(forTimeInterval: 3)
        save(XCUIScreen.main.screenshot(), name: "capture-ready")

        record.tap()
        let stop = app.buttons["Stop"]
        // Recording may be refused for lack of space on the machine; the screen then shows why.
        if stop.waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 3)
            save(XCUIScreen.main.screenshot(), name: "capture-recording")
            stop.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        save(XCUIScreen.main.screenshot(), name: "capture-after")
    }

    // Kept in the result bundle, and written as PNG under GC_ARTIFACT_DIR/screens when it is set.
    private func save(_ shot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let fm = FileManager.default
        let base = ProcessInfo.processInfo.environment["GC_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory.appendingPathComponent("gc-artifacts", isDirectory: true)
        let dir = base.appendingPathComponent("screens", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
