import Foundation
import Network
import XCTest

// Splits a stream of link messages without the app's code: each message's name and its length.
enum MessageSplitter {
    static func next(_ bytes: [UInt8]) -> (name: String, count: Int)? {
        guard bytes.count >= 2 else { return nil }
        var end: Int?
        for i in 1..<bytes.count where bytes[i] == 0x0A && bytes[i - 1] == 0x0A {
            end = i + 1
            break
        }
        guard let headerEnd = end else { return nil }
        let text = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var name = ""
        var payload = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("link.message=") { name = String(line.dropFirst("link.message=".count)) }
            if line.hasPrefix("link.bytes=") { payload = Int(line.dropFirst("link.bytes=".count)) ?? 0 }
        }
        guard bytes.count >= headerEnd + payload else { return nil }
        return (name, headerEnd + payload)
    }

    static func all(_ data: Data) -> [(name: String, bytes: Data)] {
        var rest = [UInt8](data)
        var out: [(name: String, bytes: Data)] = []
        while let m = next(rest) {
            out.append((m.name, Data(rest[0..<m.count])))
            rest.removeFirst(m.count)
        }
        return out
    }
}

// A PC for screenshots, answering with the PC's recorded bytes: a welcome (or, refusing, the
// recorded version refusal), take.accepted for a take and a pong for each ping. While live it also
// sends a progress with its behind_s every half second, and a thumbnail every 3 s; quiet, it trains
// nothing yet.
final class UITestPC {
    enum Mode {
        case live, quiet, refuse
    }

    private let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.uitests.pc")
    private var listener: NWListener?
    private var mode = Mode.live
    private var liveTicks = 0
    private let welcome: Data
    private let accepted: Data
    private let pong: Data
    private let progress: Data
    private let thumbnail: Data
    private let refused: Data

    init() throws {
        let dir = try XCTUnwrap(Bundle(for: UITestPC.self).url(forResource: "pc-wire", withExtension: nil))
        let main1 = MessageSplitter.all(try Data(contentsOf: dir.appendingPathComponent("main/conn-1.pc.bin")))
        let main2 = MessageSplitter.all(try Data(contentsOf: dir.appendingPathComponent("main/conn-2.pc.bin")))
        welcome = try XCTUnwrap(main1.first(where: { $0.name == "welcome" })).bytes
        accepted = try XCTUnwrap(main1.first(where: { $0.name == "take.accepted" })).bytes
        pong = try XCTUnwrap(main1.first(where: { $0.name == "pong" })).bytes
        progress = try XCTUnwrap(main2.first(where: {
            $0.name == "progress" && String(decoding: $0.bytes, as: UTF8.self).contains("behind_s=")
        })).bytes
        thumbnail = try XCTUnwrap(main2.first(where: { $0.name == "thumbnail" })).bytes
        refused = try Data(contentsOf: dir.appendingPathComponent("stale/conn-1.pc.bin"))
    }

    func setMode(_ m: Mode) {
        queue.sync { mode = m }
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            throw NSError(domain: "UITestPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "the listener did not start"])
        }
        self.listener = listener
        return port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    private final class Link {
        let connection: NWConnection
        var inbox: [UInt8] = []
        var timer: DispatchSourceTimer?
        var closed = false

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private func accept(_ c: NWConnection) {
        let link = Link(c)
        c.start(queue: queue)
        receive(link)
    }

    private func receive(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self = self, !link.closed else { return }
            if let data = data { link.inbox.append(contentsOf: data) }
            while let m = MessageSplitter.next(link.inbox) {
                link.inbox.removeFirst(m.count)
                self.answer(m.name, link)
            }
            if done || error != nil {
                self.close(link)
                return
            }
            self.receive(link)
        }
    }

    private func answer(_ name: String, _ link: Link) {
        switch name {
        case "hello":
            if mode == .refuse {
                link.connection.send(content: refused, completion: .contentProcessed { [weak self] _ in
                    self?.queue.async { self?.close(link) }
                })
                return
            }
            link.connection.send(content: welcome, completion: .contentProcessed { _ in })
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick(link) }
            timer.resume()
            link.timer = timer
        case "take.start":
            link.connection.send(content: accepted, completion: .contentProcessed { _ in })
        case "ping":
            link.connection.send(content: pong, completion: .contentProcessed { _ in })
        default:
            break
        }
    }

    private func tick(_ link: Link) {
        guard mode == .live else { return }
        if liveTicks % 6 == 0 {
            link.connection.send(content: thumbnail, completion: .contentProcessed { _ in })
        }
        liveTicks += 1
        link.connection.send(content: progress, completion: .contentProcessed { _ in })
    }

    private func close(_ link: Link) {
        guard !link.closed else { return }
        link.closed = true
        link.timer?.cancel()
        link.connection.cancel()
    }
}

// Screenshots of Connect, the code screen, Capture with the link chip, and the PC tab connected and
// refused, against a PC answering with its recorded bytes.
final class LinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConnectThenThePCTab() throws {
        let pc = try UITestPC()
        let port = try pc.start()
        defer { pc.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--replay-frames", "--forget-pc"]
        app.launch()

        let proceed = app.buttons["Continue"]
        if proceed.waitForExistence(timeout: 60) {
            save(name: "link-local-network")
            proceed.tap()
        }
        XCTAssertTrue(app.staticTexts["Connect to a PC"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        save(name: "link-connect")

        app.buttons["Enter an address by hand"].tap()
        let field = app.textFields["address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("127.0.0.1:\(port)\n")
        for key in ["2", "4", "6"] {
            app.buttons[key].tap()
        }
        save(name: "link-code")
        for key in ["8", "1", "3"] {
            app.buttons[key].tap()
        }

        let chip = app.staticTexts["link-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 30))
        let behind = expectation(for: NSPredicate(format: "label CONTAINS %@", "0.4 s"), evaluatedWith: chip)
        wait(for: [behind], timeout: 20)
        save(name: "link-capture")

        app.tabBars.buttons["PC"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20))
        save(name: "link-pc-connected")

        pc.setMode(.refuse)
        app.buttons["Disconnect"].tap()
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.staticTexts["Refused: versions differ"].waitForExistence(timeout: 20))
        save(name: "link-pc-refused")
    }

    // Screenshots of every state of the Training tab, and of Capture with the PC's render.
    func testTheTrainingTab() throws {
        let pc = try UITestPC()
        pc.setMode(.quiet)
        let port = try pc.start()
        defer { pc.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--replay-frames", "--forget-pc"]
        app.launch()

        let trainingTab = app.tabBars.buttons["Training"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 60))
        trainingTab.tap()
        XCTAssertTrue(app.staticTexts["Pair with a PC in the PC tab to see its training here."].waitForExistence(timeout: 10))
        save(name: "training-unpaired")

        app.tabBars.buttons["PC"].tap()
        let proceed = app.buttons["Continue"]
        if proceed.waitForExistence(timeout: 10) { proceed.tap() }
        app.buttons["Enter an address by hand"].tap()
        let field = app.textFields["address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("127.0.0.1:\(port)\n")
        for key in ["2", "4", "6", "8", "1", "3"] {
            app.buttons[key].tap()
        }
        XCTAssertTrue(app.staticTexts["link-chip"].waitForExistence(timeout: 30))

        trainingTab.tap()
        XCTAssertTrue(app.staticTexts["Waiting for the PC to start training"].waitForExistence(timeout: 10))
        save(name: "training-waiting")

        pc.setMode(.live)
        XCTAssertTrue(app.staticTexts["training-caption"].waitForExistence(timeout: 20))
        let iteration = app.staticTexts["figure-iteration"]
        let received = expectation(for: NSPredicate(format: "label != %@", "\u{2014}"), evaluatedWith: iteration)
        wait(for: [received], timeout: 10)
        save(name: "training-live")

        app.tabBars.buttons["Capture"].tap()
        let thumbnail = app.buttons["capture-thumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        save(name: "capture-thumbnail")
        thumbnail.tap()
        XCTAssertTrue(app.staticTexts["training-caption"].waitForExistence(timeout: 10))

        app.tabBars.buttons["PC"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        trainingTab.tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 10))
        save(name: "training-down")
    }

    // Kept in the result bundle, and written as PNG under GC_ARTIFACT_DIR/screens when it is set.
    private func save(name: String) {
        let shot = XCUIScreen.main.screenshot()
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
