import Foundation

enum LinkTiming {
    static let pingInterval = 2.0
    static let missedPingsDrop = 4
    static let sendStuck = 8.0
    static let readyTimeout = 5.0
    static let reconnectFirst = 0.5
    static let reconnectMax = 5.0
    static let busyHelloRetry = 0.5
    static let busyHelloWindow = 30.0
    static let takeOfferRetry = 5.0
    static let tick = 0.1
}

// One take's place in the stream: what is committed on disk, and what the PC holds. A cursor, never a
// queue of records.
struct TakeCursor: Equatable {
    let directory: URL
    let captureId: String
    private(set) var committed = -1     // highest committed index
    private(set) var last: Int? = nil   // set when the take has ended
    private(set) var next: Int? = nil   // the PC's have + 1, once it has accepted the take on this connection

    init(directory: URL, captureId: String) {
        self.directory = directory
        self.captureId = captureId
    }

    mutating func noteCommitted(_ index: Int) {
        committed = max(committed, index)
    }

    mutating func noteEnded(last: Int) {
        self.last = last
        committed = max(committed, last)
    }

    // False when the PC claims a record this phone never committed.
    mutating func accept(have: Int) -> Bool {
        guard have >= -1, have <= committed else { return false }
        next = have + 1
        return true
    }

    mutating func connectionLost() {
        next = nil
    }

    // The record to send now, if one is committed and not yet held by the PC.
    var due: Int? {
        guard let n = next, n <= committed else { return nil }
        return n
    }

    mutating func sent(_ index: Int) {
        if let n = next, n == index { next = index + 1 }
    }

    // take.stop is due: the take has ended and the PC holds every record of it.
    var stopDue: Bool {
        guard let n = next, let l = last else { return false }
        return n > l
    }

    var held: Int { next ?? 0 }
    var waiting: Int { committed + 1 - held }
}

// Reads a committed take from disk in the stream's form.
protocol RecordReader {
    func manifest(in take: URL) -> Data?
    // The record's header file, then its blobs in the bundle's order: colour, depth, confidence.
    func record(_ index: Int, in take: URL) -> Data?
}

struct DiskRecordReader: RecordReader {
    func manifest(in take: URL) -> Data? {
        try? Data(contentsOf: take.appendingPathComponent("manifest.txt"))
    }

    func record(_ index: Int, in take: URL) -> Data? {
        let records = take.appendingPathComponent("records", isDirectory: true)
        let stem = TakeStorage.recordStem(index)
        guard let headerData = try? Data(contentsOf: records.appendingPathComponent(stem + ".txt")),
              case .success(let header) = LinkFraming.parseHeader([UInt8](headerData)),
              header.byteCount == headerData.count else { return nil }
        let colorSuffix = header.value("color.encoding") == "png" ? ".color.png" : ".color.jpg"
        var blobs: [(String, String)] = [(colorSuffix, "color.bytes"), (".depth.f32", "depth.bytes")]
        if header.value("confidence.bytes") != nil {
            blobs.append((".conf.u8", "confidence.bytes"))
        }
        var out = headerData
        for (suffix, key) in blobs {
            guard let declared = header.value(key).flatMap({ LinkFraming.parseUnsigned($0) }),
                  let blob = try? Data(contentsOf: records.appendingPathComponent(stem + suffix)),
                  UInt64(blob.count) == declared else { return nil }
            out.append(blob)
        }
        return out
    }
}

protocol LinkClock: AnyObject {
    // Seconds on the clock frames are stamped with.
    var now: Double { get }
    // Calls `tick` on `queue` every `interval` seconds until the clock goes away.
    func start(every interval: Double, on queue: DispatchQueue, _ tick: @escaping () -> Void)
}

final class SystemLinkClock: LinkClock {
    private var timer: DispatchSourceTimer?

    var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(every interval: Double, on queue: DispatchQueue, _ tick: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }
}
