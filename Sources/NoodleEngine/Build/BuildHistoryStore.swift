import Foundation
import NoodleCore

/// On demand in core. No history directory or worker exists until a build starts.
struct BuildHistoryRecord: Codable, Sendable {
    var id = UUID().uuidString.lowercased()
    var tags: [String]
    var startedAt = Date()
    var endedAt: Date?
    var status = "running"
    var error: String?
    var duration: Double = 0
    var cachedSteps = 0
    var totalSteps = 0
    var contextSize: Int64
    var log = ""
}

/// Serializes record replacement and retention across concurrent classic builds.
actor BuildHistoryWriter {
    static let shared = BuildHistoryWriter()

    func cancelIfRunning(_ record: BuildHistoryRecord, root: URL) throws {
        struct Status: Decodable { var status: String }
        let file = root.appendingPathComponent("builds").appendingPathComponent(record.id + ".json")
        guard let data = try? Data(contentsOf: file),
              try JSONDecoder().decode(Status.self, from: data).status == "running" else { return }
        try write(record, root: root)
    }

    func write(_ record: BuildHistoryRecord, root: URL) throws {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("builds", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent(".lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(ISO8601.string(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        let file = directory.appendingPathComponent(record.id + ".json")
        // A removed in-flight record must not be resurrected on completion.
        if record.status != "running", !fm.fileExists(atPath: file.path) { return }
        let data = try encoder.encode(record)
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        struct Header: Decodable { var startedAt: String }
        let decoder = JSONDecoder()
        let records = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { ($0, try decoder.decode(Header.self, from: Data(contentsOf: $0))) }
            .sorted { $0.1.startedAt < $1.1.startedAt }
        let configured = ProcessInfo.processInfo.environment["NOODLE_BUILD_HISTORY_LIMIT"].flatMap(Int.init) ?? 100
        let limit = min(100, max(1, configured))
        for (url, _) in records.prefix(max(0, records.count - limit)) { try fm.removeItem(at: url) }
    }
}
