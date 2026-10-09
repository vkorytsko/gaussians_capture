import Foundation
import UIKit

// Called on the writer queue right after a record's commit; returns at once.
protocol TakeCommitListener: AnyObject {
    func takeCommitted(directory: URL, captureId: String, index: Int)
    func takeEnded(directory: URL, captureId: String, last: Int)
}

struct LinkStatus: Equatable {
    enum Phase: Equatable {
        case unpaired
        case disconnected
        case connecting
        case connected
        case reconnecting
        case waiting(String)        // the network or a policy holds the connection
        case refused(String)        // a reason only the user can resolve: code, token, version, pairing closed
    }

    var phase = Phase.unpaired
    var paired = false              // a token is held; until then the app shows Connect
    var refusalDetail: String? = nil // the PC's detail with a refusal, such as both versions
    var lastDrop: String? = nil      // why the link last dropped
    var pcName: String? = nil
    var address: String? = nil
    var connectedSince: Double? = nil
    var captureId: String? = nil    // the take being sent
    var held = 0                    // its records the PC holds
    var committed = 0               // its records committed on the phone
    var waiting = 0                 // records not yet held by the PC, across this process's takes
    var takeRefused: String? = nil  // why the PC refused the take; it is offered again while connected
    var behindS: Double? = nil
}

// Main queue.
protocol LinkObserver: AnyObject {
    func linkChanged(_ status: LinkStatus)
}

// The phone's side of the link. One per process, on its own serial queue, which owns every var below:
// the connection, its timers and its file reads. Its only input from capture is the writer's commit
// notice; it sends committed records from disk, in order, one at a time. Main reads a status it
// publishes at most 10 times a second.
final class LinkClient: TakeCommitListener {
    static let shared = LinkClient(dialer: NWLinkDialer(), reader: DiskRecordReader(), clock: SystemLinkClock(),
                                   store: PairingStore())

    let queue = DispatchQueue(label: "com.vkorytsko.gaussianscapture.link", qos: .userInitiated)
    weak var observer: LinkObserver?

    private let dialer: LinkDialer
    private let reader: RecordReader
    private let clock: LinkClock
    private let store: PairingStore
    private let phoneName: String
    private let appVersion: String

    private var target: LinkTarget?
    private var token: String?
    private var code: String?               // sent once, in the next hello; never stored
    private var foreground = false
    private var userDisconnected = false
    private var refusal: String?
    private var refusalDetail: String?
    private var lastDrop: String?
    private var everConnected = false

    private var transport: LinkTransport?
    private var dialedAt = 0.0
    private var ready = false
    private var waitingText: String?
    private var inbox: [UInt8] = []
    private var welcomed = false
    private var connectedSince: Double?
    private var pingsOutstanding = 0
    private var lastPingAt = 0.0
    private var recordInFlight = false
    private var recordSentAt: Double?
    private var stopInFlight = false
    private var takeOffered = false
    private var pingsSent = 0
    private var pongsReceived = 0
    // A take whose take.stop went out stays until the pong to a ping sent after it: the PC answers
    // pings in order, so that pong proves it read the take.stop. A link lost before then resends it.
    private var stopAwaitingPong: (captureId: String, pong: Int)?

    private var takes: [TakeCursor] = []
    private var takeOfferAt: Double?
    private var takeRefused: String?
    private var reconnectAt: Double?
    private var reconnectDelay = LinkTiming.reconnectFirst
    private var busySince: Double?
    private var behindS: Double?
    private(set) var lastProgress: LinkMessage?
    private(set) var lastThumbnail: LinkMessage?

    private var published: LinkStatus?
    private var publishedAt = -Double.infinity

    init(dialer: LinkDialer, reader: RecordReader, clock: LinkClock, store: PairingStore,
         phoneName: String = PhoneName.fold(UIDevice.current.name), appVersion: String = TakeInfo.appVersion()) {
        self.dialer = dialer
        self.reader = reader
        self.clock = clock
        self.store = store
        self.phoneName = phoneName
        self.appVersion = appVersion
        token = store.token()
        target = token == nil ? nil : store.target
        clock.start(every: LinkTiming.tick, on: queue) { [weak self] in self?.tick() }
    }

    // MARK: Commands, from any thread.

    // The app is active (true) or has left it. In the background the connection is closed, so the
    // PC sees a close rather than silence.
    func setForeground(_ on: Bool) {
        queue.async {
            self.foreground = on
            if on {
                self.reconnectDelay = LinkTiming.reconnectFirst
                self.dial()
            } else {
                self.closeTransport()
                self.reconnectAt = nil
            }
        }
    }

    // Pairs with a PC by its code, replacing any PC paired before.
    func pair(target: LinkTarget, code: String) {
        queue.async {
            self.closeTransport()
            self.store.forget()
            self.token = nil
            self.store.target = target
            self.target = target
            self.code = code
            self.refusal = nil
            self.refusalDetail = nil
            self.busySince = nil
            self.userDisconnected = false
            self.everConnected = false
            self.reconnectDelay = LinkTiming.reconnectFirst
            self.dial()
        }
    }

    // A gaussians://pair URL, from the QR or the system's scanner. False when it does not parse.
    @discardableResult
    func pair(url: String) -> Bool {
        guard let p = PairingURL.parse(url) else { return false }
        pair(target: .hostPort(p.host, p.port), code: p.code)
        return true
    }

    // Closes the link and keeps the pairing until connect().
    func disconnect() {
        queue.async {
            self.userDisconnected = true
            self.closeTransport()
            self.reconnectAt = nil
        }
    }

    func connect() {
        queue.async {
            self.userDisconnected = false
            self.refusal = nil
            self.refusalDetail = nil
            self.reconnectDelay = LinkTiming.reconnectFirst
            self.dial()
        }
    }

    // Deletes the token, the PC's name and its address, and closes the link. The PC keeps its entry
    // until its own Forget: link version 1 cannot tell it.
    func forget() {
        queue.async {
            self.closeTransport()
            self.store.forget()
            self.token = nil
            self.code = nil
            self.target = nil
            self.reconnectAt = nil
            self.refusal = nil
            self.refusalDetail = nil
            self.busySince = nil
        }
    }

    // MARK: TakeCommitListener, on the writer queue.

    func takeCommitted(directory: URL, captureId: String, index: Int) {
        queue.async {
            guard self.target != nil else { return }
            if let i = self.takes.firstIndex(where: { $0.captureId == captureId }) {
                self.takes[i].noteCommitted(index)
            } else {
                var cursor = TakeCursor(directory: directory, captureId: captureId)
                cursor.noteCommitted(index)
                self.takes.append(cursor)
            }
            self.pump()
        }
    }

    func takeEnded(directory: URL, captureId: String, last: Int) {
        queue.async {
            guard let i = self.takes.firstIndex(where: { $0.captureId == captureId }) else { return }
            self.takes[i].noteEnded(last: last)
            self.pump()
        }
    }

    // MARK: The connection, on the link queue.

    private var shouldConnect: Bool {
        target != nil && (token != nil || code != nil) && foreground && !userDisconnected && refusal == nil
    }

    private func dial() {
        guard transport == nil, shouldConnect, let target = target else { return }
        reconnectAt = nil
        let t = dialer.dial(target)
        transport = t
        dialedAt = clock.now
        ready = false
        inbox = []
        t.events = { [weak self, weak t] event in
            guard let self = self, let t = t, self.transport === t else { return }
            self.handle(event)
        }
        t.start(queue: queue)
    }

    private func handle(_ event: LinkTransportEvent) {
        switch event {
        case .ready:
            ready = true
            waitingText = nil
            sendHello()
        case .waiting(let text):
            waitingText = text
        case .received(let data):
            inbox.append(contentsOf: data)
            drain(streamEnded: false)
        case .ended(let why):
            drain(streamEnded: true)
            if transport != nil { drop(why ?? "the PC closed the link") }
        }
    }

    private func drain(streamEnded: Bool) {
        while transport != nil {
            switch LinkFraming.decode(inbox, streamEnded: streamEnded) {
            case .failure(let error):
                if error.kind == .version {
                    halt("version")
                } else {
                    drop(error.text)
                }
                return
            case .success(.incomplete):
                return
            case .success(.message(let message, let consumed)):
                inbox.removeFirst(consumed)
                pingsOutstanding = 0
                receive(message)
            }
        }
    }

    private func sendHello() {
        var fields = [("phone.name", phoneName), ("app.version", appVersion)]
        if let token = token {
            fields.append(("pair.token", token))
        } else if let code = code {
            fields.append(("pair.code", code))
        } else {
            closeTransport()
            return
        }
        send(LinkMessage(.hello, fields))
    }

    private func receive(_ m: LinkMessage) {
        let now = clock.now
        switch m.type {
        case .ping:
            send(LinkMessage(.pong))
        case .pong:
            pongsReceived += 1
            if let awaiting = stopAwaitingPong, pongsReceived >= awaiting.pong {
                stopAwaitingPong = nil
                takes.removeAll(where: { $0.captureId == awaiting.captureId })
                pump()
            }
        case .welcome:
            if let issued = m.value("pair.token") {
                token = issued
                store.setToken(issued)
            }
            if let name = m.value("pc.name") { store.pcName = name }
            code = nil
            welcomed = true
            everConnected = true
            connectedSince = now
            lastPingAt = now
            reconnectDelay = LinkTiming.reconnectFirst
            busySince = nil
            refusalDetail = nil
            pump()
        case .refused:
            let reason = m.value("reason") ?? ""
            refusalDetail = m.value("detail")
            if reason == "busy" {
                // The PC still holds a dropped link of this phone: hello again soon, for a while.
                closeTransport()
                let since = busySince ?? now
                busySince = since
                if now - since < LinkTiming.busyHelloWindow {
                    reconnectAt = now + LinkTiming.busyHelloRetry
                } else {
                    busySince = nil
                    scheduleReconnect()
                }
            } else {
                if reason == "token" {
                    token = nil
                    store.deleteToken()
                }
                if reason == "code" { code = nil }
                halt(reason.isEmpty ? "refused" : reason)
            }
        case .takeAccepted:
            guard takeOffered, !takes.isEmpty,
                  let haveText = m.value("have"), let have = Int(haveText), takes[0].accept(have: have) else {
                drop("take.accepted that does not fit the take offered")
                return
            }
            takeOffered = false
            takeRefused = nil
            pump()
        case .takeRefused:
            guard takeOffered, !takes.isEmpty else {
                drop("take.refused with no take offered")
                return
            }
            takeOffered = false
            let reason = m.value("reason") ?? ""
            takeRefused = reason
            if reason == "busy" {
                takeOfferAt = now + LinkTiming.takeOfferRetry
            } else {
                // The PC cannot take it at all; it stays on disk, to be copied by file.
                takes.removeFirst()
                pump()
            }
        case .progress:
            lastProgress = m
            behindS = m.value("behind_s").flatMap { Double($0) }
        case .thumbnail:
            lastThumbnail = m
        default:
            drop("\(m.type.rawValue) is not a PC's message")
        }
    }

    // Offers the head take, or sends its next record, or its take.stop: one at a time.
    private func pump() {
        guard welcomed, transport != nil, !recordInFlight, !stopInFlight, !takeOffered, stopAwaitingPong == nil,
              !takes.isEmpty else { return }
        let head = takes[0]
        if head.next == nil {
            if let at = takeOfferAt, clock.now < at { return }
            takeOfferAt = nil
            guard let manifest = reader.manifest(in: head.directory) else {
                takes.removeFirst()
                pump()
                return
            }
            takeOffered = true
            send(LinkMessage(.takeStart, [("capture.id", head.captureId)], payload: manifest))
            return
        }
        if let index = head.due {
            guard let bytes = reader.record(index, in: head.directory) else {
                drop("record \(index) of \(head.captureId) could not be read")
                return
            }
            let age = max(0, Int(((clock.now - LinkClient.timestamp(of: bytes)) * 1000).rounded(.down)))
            recordInFlight = true
            recordSentAt = clock.now
            let captureId = head.captureId
            send(LinkMessage(.record, [("age_ms", String(age))], payload: bytes)) { [weak self] in
                guard let self = self else { return }
                self.recordInFlight = false
                self.recordSentAt = nil
                if let i = self.takes.firstIndex(where: { $0.captureId == captureId }) { self.takes[i].sent(index) }
                self.pump()
            }
            return
        }
        if head.stopDue, let last = head.last {
            stopInFlight = true
            let captureId = head.captureId
            send(LinkMessage(.takeStop, [("last", String(last))])) { [weak self] in
                guard let self = self else { return }
                self.stopInFlight = false
                self.sendPing()
                self.stopAwaitingPong = (captureId, self.pingsSent)
            }
        }
    }

    static func timestamp(of record: Data) -> Double {
        let prefix = [UInt8](record.prefix(LinkFraming.headerMaxBytes))
        guard case .success(let header) = LinkFraming.parseHeader(prefix),
              let text = header.value("frame.timestamp_s"), let t = Double(text) else { return 0 }
        return t
    }

    // `sent` runs once the bytes are handed to the network, on this connection only.
    private func send(_ m: LinkMessage, sent: (() -> Void)? = nil) {
        guard let t = transport, let data = LinkFraming.encode(m) else { return }
        t.send(data) { [weak self, weak t] error in
            guard let self = self, let t = t, self.transport === t else { return }
            if let error = error {
                self.drop("send failed: " + error)
                return
            }
            sent?()
        }
    }

    private func tick() {
        let now = clock.now
        if transport == nil {
            if let at = reconnectAt, now >= at {
                reconnectAt = nil
                dial()
            }
        } else if !ready {
            if now - dialedAt >= LinkTiming.readyTimeout { drop(waitingText ?? "not reachable") }
        } else if welcomed {
            if now - lastPingAt >= LinkTiming.pingInterval {
                if pingsOutstanding >= LinkTiming.missedPingsDrop {
                    drop("\(pingsOutstanding) pings unanswered")
                } else {
                    sendPing()
                }
            }
            if let at = recordSentAt, now - at >= LinkTiming.sendStuck {
                drop("a record unsent for \(LinkTiming.sendStuck) s")
            }
            pump()
        }
        publish(now)
    }

    private func sendPing() {
        send(LinkMessage(.ping))
        pingsSent += 1
        pingsOutstanding += 1
        lastPingAt = clock.now
    }

    private func drop(_ why: String) {
        lastDrop = why
        closeTransport()
        scheduleReconnect()
    }

    private func halt(_ reason: String) {
        closeTransport()
        refusal = reason
        reconnectAt = nil
    }

    private func scheduleReconnect() {
        guard shouldConnect else { return }
        reconnectAt = clock.now + reconnectDelay
        reconnectDelay = min(LinkTiming.reconnectMax, reconnectDelay * 2)
    }

    private func closeTransport() {
        guard let t = transport else { return }
        transport = nil
        t.events = nil
        t.cancel()
        ready = false
        welcomed = false
        inbox = []
        connectedSince = nil
        pingsOutstanding = 0
        recordInFlight = false
        recordSentAt = nil
        stopInFlight = false
        takeOffered = false
        pingsSent = 0
        pongsReceived = 0
        stopAwaitingPong = nil
        for i in takes.indices { takes[i].connectionLost() }
    }

    // MARK: Status.

    // The status as of now, on the link queue.
    func status() -> LinkStatus {
        var s = LinkStatus()
        if target == nil {
            s.phase = .unpaired
        } else if let r = refusal {
            s.phase = .refused(r)
        } else if busySince != nil && !welcomed {
            s.phase = .refused("busy")
        } else if userDisconnected || !foreground {
            s.phase = .disconnected
        } else if welcomed {
            s.phase = .connected
        } else if let w = waitingText {
            s.phase = .waiting(w)
        } else {
            s.phase = everConnected ? .reconnecting : .connecting
        }
        s.paired = target != nil && token != nil
        s.refusalDetail = refusalDetail
        s.lastDrop = lastDrop
        s.pcName = target == nil ? nil : store.pcName
        s.address = target?.text
        s.connectedSince = connectedSince
        if let head = takes.first {
            s.captureId = head.captureId
            s.held = head.held
            s.committed = head.committed + 1
        }
        s.waiting = takes.reduce(0) { $0 + $1.waiting }
        s.takeRefused = takeRefused
        s.behindS = behindS
        return s
    }

    private func publish(_ now: Double) {
        guard now - publishedAt >= 0.1 else { return }
        let s = status()
        guard s != published else { return }
        published = s
        publishedAt = now
        DispatchQueue.main.async { [weak self] in self?.observer?.linkChanged(s) }
    }
}
