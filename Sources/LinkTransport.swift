import Foundation
import Network

enum LinkTransportEvent {
    case ready
    case waiting(String)        // not reachable yet, or a policy such as local network access refused
    case received(Data)
    case ended(String?)         // nil: the peer closed; otherwise why the connection failed
}

// One connection. Events and send completions arrive on the queue given to start.
protocol LinkTransport: AnyObject {
    var events: ((LinkTransportEvent) -> Void)? { get set }
    func start(queue: DispatchQueue)
    // `completion` gets nil once the bytes are handed to the network, or why they were not.
    func send(_ data: Data, completion: @escaping (String?) -> Void)
    func cancel()
}

protocol LinkDialer {
    func dial(_ target: LinkTarget) -> LinkTransport
}

struct NWLinkDialer: LinkDialer {
    func dial(_ target: LinkTarget) -> LinkTransport {
        NWLinkTransport(target)
    }
}

// TCP through Network.framework. A receive is always outstanding, independent of sends.
final class NWLinkTransport: LinkTransport {
    var events: ((LinkTransportEvent) -> Void)?
    private let connection: NWConnection
    private var finished = false

    init(_ target: LinkTarget) {
        switch target {
        case .hostPort(let host, let port):
            connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: LinkFraming.defaultPort)!,
                                      using: .tcp)
        case .service(let name):
            connection = NWConnection(to: .service(name: name, type: LinkTarget.serviceType, domain: "local.", interface: nil),
                                      using: .tcp)
        }
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.events?(.ready)
                self.receiveNext()
            case .waiting(let error):
                self.events?(.waiting(String(describing: error)))
            case .failed(let error):
                self.finish(String(describing: error))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error.map { String(describing: $0) })
        })
    }

    func cancel() {
        finished = true
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = data, !data.isEmpty {
                self.events?(.received(data))
            }
            if let error = error {
                self.finish(String(describing: error))
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(_ why: String?) {
        guard !finished else { return }
        finished = true
        events?(.ended(why))
        connection.cancel()
    }
}

// Bonjour instances of the PC's service. Runs only while the Connect screen shows; the first browse is
// what asks for local network access. Results arrive on the main queue.
final class PCBrowser {
    private var browser: NWBrowser?
    var onChange: (([String]) -> Void)?
    var onWaiting: ((String) -> Void)?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: LinkTarget.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var names: [String] = []
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint { names.append(name) }
            }
            self?.onChange?(names.sorted())
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state { self?.onWaiting?(String(describing: error)) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
