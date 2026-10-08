import Foundation
import XCTest
@testable import GaussiansCapture

enum TestFiles {
    static func temporaryRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-tests-" + name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // GC_ARTIFACT_DIR when the test runner is given one, else a fixed temporary directory.
    static func artifactDirectory() throws -> URL {
        let fm = FileManager.default
        let url = ProcessInfo.processInfo.environment["GC_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory.appendingPathComponent("gc-artifacts", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func replace(_ destination: URL, withCopyOf source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}

// Reads a written take only as far as these tests need: problems found, none for a whole take.
enum TakeLayout {
    static let blobs: [(suffix: String, key: String, required: Bool)] = [
        (".color.jpg", "color.bytes", true),
        (".depth.f32", "depth.bytes", true),
        (".conf.u8", "confidence.bytes", false),
    ]

    static func value(_ header: String, _ key: String) -> String? {
        for line in header.split(separator: "\n") where line.hasPrefix(key + "=") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    static func fileSize(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    static func problems(in take: URL) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        guard let manifest = try? String(contentsOf: take.appendingPathComponent("manifest.txt"), encoding: .utf8) else {
            return ["no manifest.txt"]
        }
        if !manifest.hasPrefix("# gd-capture-bundle\n") {
            problems.append("manifest.txt has no magic line")
        }
        let records = take.appendingPathComponent("records", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: records.path)) ?? []
        let headers = names.filter { $0.hasSuffix(".txt") }.sorted()
        if headers.isEmpty {
            problems.append("no committed record")
        }
        var lastTimestamp = -Double.infinity
        for (k, name) in headers.enumerated() {
            let stem = TakeStorage.recordStem(k)
            guard name == stem + ".txt" else {
                problems.append("record \(k): found \(name), a gap")
                break
            }
            guard let header = try? String(contentsOf: records.appendingPathComponent(name), encoding: .utf8) else {
                problems.append("record \(k): header unreadable")
                continue
            }
            let index = value(header, "frame.index")
            if index != String(k) {
                problems.append("record \(k): frame.index=\(index ?? "missing")")
            }
            if let timestamp = value(header, "frame.timestamp_s").flatMap({ Double($0) }) {
                if !(timestamp > lastTimestamp) {
                    problems.append("record \(k): timestamp not after the previous record's")
                }
                lastTimestamp = timestamp
            } else {
                problems.append("record \(k): no frame.timestamp_s")
            }
            for blob in blobs {
                guard let declared = value(header, blob.key).flatMap({ Int($0) }) else {
                    if blob.required { problems.append("record \(k): no \(blob.key)") }
                    continue
                }
                let size = fileSize(records.appendingPathComponent(stem + blob.suffix))
                if size != declared {
                    problems.append("record \(k): \(stem + blob.suffix) is \(size.map { String($0) } ?? "missing"), declared \(declared)")
                }
            }
        }
        return problems + orphans(in: take)
    }

    // Blobs with no header, and headers never renamed into place.
    static func orphans(in take: URL) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let top = (try? fm.contentsOfDirectory(atPath: take.path)) ?? []
        found += top.filter { $0.hasSuffix(".tmp") }
        let records = take.appendingPathComponent("records", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: records.path)) ?? []
        let headers = Set(names.filter { $0.hasSuffix(".txt") })
        for name in names.sorted() {
            if name.hasSuffix(".tmp") {
                found.append("records/" + name)
                continue
            }
            guard TakeStorage.blobSuffixes.contains(where: { name.hasSuffix($0) }) else { continue }
            let stem = name.split(separator: ".").first.map { String($0) } ?? name
            if !headers.contains(stem + ".txt") {
                found.append("records/" + name)
            }
        }
        return found
    }
}
