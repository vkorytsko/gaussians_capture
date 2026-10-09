import Foundation
import Network
import XCTest
@testable import GaussiansCapture

// A PC's recording: its script, and per connection the bytes the PC sent.
struct PCRecording {
    let name: String
    let script: [String]
    let pcBytes: [Int: [UInt8]]
    let qr: String?

    static func directory() throws -> URL {
        try XCTUnwrap(Bundle(for: ScriptedPC.self).url(forResource: "pc-wire", withExtension: nil))
    }

    static func load(_ name: String) throws -> PCRecording {
        let dir = try directory().appendingPathComponent(name, isDirectory: true)
        let script = try WireScript.read(dir)
        var bytes: [Int: [UInt8]] = [:]
        for line in script.dropFirst() {
            guard let n = Int(line.split(separator: " ").first ?? ""), bytes[n] == nil else { continue }
            bytes[n] = [UInt8](try Data(contentsOf: dir.appendingPathComponent("conn-\(n).pc.bin")))
        }
        let qr = try? String(contentsOf: dir.appendingPathComponent("qr.txt"), encoding: .utf8)
        return PCRecording(name: name, script: script, pcBytes: bytes, qr: qr)
    }

    // The events of connection `conn`, each split into its words.
    func events(_ conn: Int) -> [[String]] {
        script.dropFirst().map { $0.split(separator: " ").map(String.init) }.filter { $0.first == String(conn) }
    }

    // The PC's messages on connection `conn`, in order, with their bytes; nil when they do not decode.
    func messages(_ conn: Int) -> [(message: LinkMessage, raw: Data)]? {
        var rest = pcBytes[conn] ?? []
        var out: [(message: LinkMessage, raw: Data)] = []
        while !rest.isEmpty {
            guard case .success(.message(let m, let n)) = LinkFraming.decode(rest, streamEnded: true) else { return nil }
            out.append((m, Data(rest[0..<n])))
            rest.removeFirst(n)
        }
        return out
    }
}

// A PC that answers from its recording. Each connection the phone opens plays the next of `plays`:
// the PC's messages are sent in script order, each after the phone message the script puts before it,
// and the connection ends as the script ends it. A phone cut becomes this PC's: it ends the link with
// the phone's next record unread. The recording's pings are sent; the phone's pings, whose timing is
// the phone's, are answered in the order they arrive among its other messages. Connections beyond
// `plays` are closed at once.
final class ScriptedPC {
    struct Play {
        let recording: PCRecording
        let connection: Int
        var silentAfterRecords: Int? = nil   // after this many phone records, send nothing more
        var answerPingsWhileSilent = false
    }

    struct Observed {
        var accepted: [LinkMessage] = []     // phone messages the script consumed, pings and pongs aside
        var pcPingsSent = 0
        var phonePongs = 0
        var failure: String?
        var silentSince: Double?
        var endedAt: Double?
        var endedBy: String?
    }

    let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.tests.scripted-pc")
    var onEnded: ((Int) -> Void)?
    private let plays: [Play]
    private var listener: NWListener?
    private var sessions: [Int: Session] = [:]
    private var count = 0
    private var observedByConnection: [Int: Observed] = [:]

    private final class Session {
        let number: Int
        let connection: NWConnection
        let play: Play?
        let events: [[String]]
        var pcMessages: [(message: LinkMessage, raw: Data)]
        var inbox: [UInt8] = []
        var phoneQueue: [LinkMessage] = []
        var next = 0
        var records = 0
        var silent = false
        var ended = false
        var pongWaitStarted: Double?

        init(_ number: Int, _ connection: NWConnection, _ play: Play?) {
            self.number = number
            self.connection = connection
            self.play = play
            events = play.map { $0.recording.events($0.connection) } ?? []
            pcMessages = play.flatMap { $0.recording.messages($0.connection) } ?? []
        }
    }

    init(plays: [Play]) {
        self.plays = plays
    }

    static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    func observed(_ conn: Int) -> Observed {
        queue.sync { observedByConnection[conn] ?? Observed() }
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "ScriptedPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "the listener did not start"])
        }
        self.listener = listener
        return port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for s in sessions.values where !s.ended {
                s.ended = true
                s.connection.cancel()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        count += 1
        let play = count <= plays.count ? plays[count - 1] : nil
        let s = Session(count, connection, play)
        sessions[s.number] = s
        observedByConnection[s.number] = Observed()
        connection.start(queue: queue)
        if play == nil {
            end(s, by: "pc")
            return
        }
        if s.pcMessages.count != s.events.filter({ $0.count == 3 && $0[1] == "pc" }).count {
            fail(s, "the recording's pc.bin does not hold its script's pc messages")
            return
        }
        receive(s)
    }

    private func receive(_ s: Session) {
        s.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self, !s.ended else { return }
            if let data = data, !data.isEmpty {
                s.inbox.append(contentsOf: data)
                self.intake(s)
                self.advance(s)
            }
            if s.ended { return }
            if isComplete || error != nil {
                self.end(s, by: "phone")
                return
            }
            self.receive(s)
        }
    }

    private func intake(_ s: Session) {
        while !s.ended {
            switch LinkFraming.decode(s.inbox, streamEnded: false) {
            case .failure(let e):
                fail(s, "the phone sent bytes that do not decode: " + e.text)
                return
            case .success(.incomplete):
                return
            case .success(.message(let m, let n)):
                s.inbox.removeFirst(n)
                switch m.type {
                case .ping where s.silent:
                    if s.play?.answerPingsWhileSilent == true { pong(s) }
                case .pong:
                    observedByConnection[s.number]?.phonePongs += 1
                default:
                    s.phoneQueue.append(m)
                }
            }
        }
    }

    private func advance(_ s: Session) {
        guard let play = s.play else { return }
        while !s.ended && !s.silent && s.next < s.events.count {
            // A ping is answered when it is reached, after every phone message before it, as a PC
            // that reads in order answers it.
            while s.phoneQueue.first?.type == .ping {
                s.phoneQueue.removeFirst()
                pong(s)
            }
            let e = s.events[s.next]
            if e.count == 3 && e[1] == "phone" {
                if e[2] == "ping" || e[2] == "pong" {
                    s.next += 1
                    continue
                }
                guard !s.phoneQueue.isEmpty else { return }
                let m = s.phoneQueue.removeFirst()
                guard m.type.rawValue == e[2] else {
                    fail(s, "the script expects the phone's \(e[2]) and the phone sent \(m.type.rawValue)")
                    return
                }
                observedByConnection[s.number]?.accepted.append(m)
                s.next += 1
                if m.type == .record {
                    s.records += 1
                    if let n = play.silentAfterRecords, s.records >= n {
                        s.silent = true
                        observedByConnection[s.number]?.silentSince = ScriptedPC.now()
                        return
                    }
                }
            } else if e.count == 3 && e[1] == "pc" {
                let (m, raw) = s.pcMessages.removeFirst()
                guard m.type.rawValue == e[2] else {
                    fail(s, "the script's pc \(e[2]) is \(m.type.rawValue) in pc.bin")
                    return
                }
                s.next += 1
                if m.type == .pong { continue }
                send(raw, s)
                if m.type == .ping { observedByConnection[s.number]?.pcPingsSent += 1 }
            } else if e.count == 4 && e[1] == "end" {
                // Every ping this PC sent gets its answer before the end, or 3 s pass.
                let o = observedByConnection[s.number] ?? Observed()
                if o.phonePongs < o.pcPingsSent {
                    let started = s.pongWaitStarted ?? ScriptedPC.now()
                    if s.pongWaitStarted == nil {
                        s.pongWaitStarted = started
                        queue.asyncAfter(deadline: .now() + 3.05) { [weak self] in self?.advance(s) }
                    }
                    if ScriptedPC.now() - started < 3 { return }
                }
                if e[2] == "cut" && e[3] == "phone" {
                    guard s.phoneQueue.contains(where: { $0.type == .record }) else { return }
                    end(s, by: "pc")
                } else if e[3] == "pc" {
                    end(s, by: "pc")
                }
                return
            } else {
                fail(s, "a script line this PC cannot play: " + e.joined(separator: " "))
                return
            }
        }
    }

    private func pong(_ s: Session) {
        send(LinkFraming.encode(LinkMessage(.pong))!, s)
    }

    private func send(_ raw: Data, _ s: Session) {
        s.connection.send(content: raw, completion: .contentProcessed { _ in })
    }

    private func fail(_ s: Session, _ why: String) {
        observedByConnection[s.number]?.failure = why
        end(s, by: "pc")
    }

    private func end(_ s: Session, by side: String) {
        guard !s.ended else { return }
        s.ended = true
        observedByConnection[s.number]?.endedAt = ScriptedPC.now()
        observedByConnection[s.number]?.endedBy = side
        s.connection.cancel()
        onEnded?(s.number)
    }
}

// Rebuilds the take a PC would store from the phone messages it accepted: the manifest from take.start,
// each record under its index.
func rebuildTake(from messages: [LinkMessage], into take: URL) -> Bool {
    try? FileManager.default.createDirectory(at: take.appendingPathComponent("records", isDirectory: true),
                                             withIntermediateDirectories: true)
    for m in messages {
        switch m.type {
        case .takeStart:
            guard (try? m.payload.write(to: take.appendingPathComponent("manifest.txt"))) != nil else { return false }
        case .record:
            guard case .success(let h) = LinkFraming.parseHeader([UInt8](m.payload.prefix(LinkFraming.headerMaxBytes))),
                  let index = h.value("frame.index").flatMap({ Int($0) }),
                  writeStreamRecord(m.payload, index, into: take) else { return false }
        default:
            break
        }
    }
    return true
}

func recordIndexes(_ messages: [LinkMessage]) -> [Int] {
    messages.filter { $0.type == .record }.compactMap { m in
        guard case .success(let h) = LinkFraming.parseHeader([UInt8](m.payload.prefix(LinkFraming.headerMaxBytes))) else { return nil }
        return h.value("frame.index").flatMap { Int($0) }
    }
}
