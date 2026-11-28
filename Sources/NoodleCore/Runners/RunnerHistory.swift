import Foundation

/// One finished job in `RunnerState.history`. Names and URLs only: never a token or a JIT config.
public struct RunnerJobRecord: Codable, Equatable, Sendable {
    public var repo: String
    public var name: String
    public var url: String
    public var conclusion: String?
    /// When the runner ended.
    public var at: Date
    public var kind: RunnerKind
    /// How long the job ran, from GitHub's timestamps, else the runner's lifetime.
    public var seconds: Int
    /// The runner's log file name inside `RunnerStore.logDirectory`, not a path. Read it with `RunnerStore.logTail`.
    public var log: String

    public init(repo: String, name: String, url: String, conclusion: String?, at: Date, kind: RunnerKind, seconds: Int, log: String) {
        self.repo = repo; self.name = name; self.url = url; self.conclusion = conclusion
        self.at = at; self.kind = kind; self.seconds = seconds; self.log = log
    }
}

extension RunnerState {
    public static let historyLimit = 50

    /// Newest first, capped at `historyLimit`.
    public mutating func record(_ job: RunnerJobRecord) {
        history = Array(([job] + (history ?? [])).prefix(Self.historyLimit))
    }
}

extension RunnerStore {
    /// Total size the helper keeps in `logs`; the oldest files go first.
    public static let logBytesLimit = 50 << 20

    /// The last `maxBytes` of a job's log. Nil for a name that is not a plain file inside the logs directory.
    public func logTail(for job: RunnerJobRecord, maxBytes: Int = 64 << 10) -> String? {
        let name = job.log
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        let url = logDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == logDirectory.resolvingSymlinksInPath().path,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Keeps the newest `keep` logs (as many as the history holds) within `maxBytes` in total, deleting the oldest.
    /// The newest log and the logs of running jobs (`running`, file names) are never deleted.
    public func pruneLogs(keep: Int = RunnerState.historyLimit, maxBytes: Int = RunnerStore.logBytesLimit, running: Set<String> = []) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: keys)) ?? []).map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (i, f) in files.enumerated() {
            total += f.2
            if i > 0, !running.contains(f.0.lastPathComponent), i >= keep || total > maxBytes { try? fm.removeItem(at: f.0) }
        }
    }

    /// A size for people; zero reads "0 KB", not the formatter's "Zero KB".
    public static func sizeText(_ n: Int64) -> String { n == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// Bytes on disk under a folder, or of a single file; 0 when it is missing.
    public static func diskBytes(_ folder: URL) -> Int64 { diskBytes(folder, maxEntries: .max) ?? 0 }

    /// As `diskBytes(_:)`, but nil once the walk passes `maxEntries` files and folders, so a huge folder costs a bounded time.
    public static func diskBytes(_ folder: URL, maxEntries: Int) -> Int64? {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        if let v = try? folder.resourceValues(forKeys: [key, .isRegularFileKey]), v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key]) else { return 0 }
        var total: Int64 = 0, seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > maxEntries { return nil }
            total += Int64((try? url.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The downloaded macOS runner installs (`macos-runner-<version>`).
    public var installDirectories: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("macos-runner-") }
    }
}
