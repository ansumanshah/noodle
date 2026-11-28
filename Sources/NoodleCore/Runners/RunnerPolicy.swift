import Foundation

// MARK: - Visibility

/// A repo can turn public after `add` checked it. The helper asks again before it registers a runner, at most once
/// per `ttl` per repo, and skips a public repo unless it was added with `--allow-public`.
public struct RunnerVisibility: Sendable {
    public static let ttl: TimeInterval = 300
    private var checked: [String: (isPrivate: Bool, at: Date)] = [:]
    public init() {}

    /// Nil when the repo may get a runner, else the reason for the state message. Errors from `isPrivate` pass
    /// through uncached, so the caller's backoff sees them.
    public mutating func refusal(_ repo: RunnerRepo, now: Date = Date(), isPrivate: (String) throws -> Bool) rethrows -> String? {
        if repo.allowPublic == true { return nil }
        let key = repo.repo.lowercased()
        if let hit = checked[key], now.timeIntervalSince(hit.at) < Self.ttl { return Self.reason(repo.repo, hit.isPrivate) }
        let flag = try isPrivate(repo.repo)
        checked[key] = (flag, now)
        return Self.reason(repo.repo, flag)
    }

    /// The refusal from a check still within `ttl`, without asking GitHub; nil when allowed or not known.
    public func knownRefusal(_ repo: RunnerRepo, now: Date = Date()) -> String? {
        guard repo.allowPublic != true, let hit = checked[repo.repo.lowercased()], now.timeIntervalSince(hit.at) < Self.ttl else { return nil }
        return Self.reason(repo.repo, hit.isPrivate)
    }

    static func reason(_ repo: String, _ isPrivate: Bool) -> String? {
        isPrivate ? nil : "\(repo) is public now, so it gets no runners: a pull request from a fork could run code here. "
            + "Make it private, or run `noodle runners add \(repo) --allow-public` to accept that."
    }
}

// MARK: - Caches

/// What `noodle runners cache --json` prints.
public struct RunnerCacheReport: Codable, Equatable, Sendable {
    public struct Volume: Codable, Equatable, Sendable {
        public var repo: String?
        public var volume: String
        /// Nil when the engine could not size it.
        public var bytes: Int64?
        public init(repo: String?, volume: String, bytes: Int64?) { self.repo = repo; self.volume = volume; self.bytes = bytes }
    }
    /// False when the engine is not running, so `volumes` is empty rather than known to be empty.
    public var engine: Bool
    public var volumes: [Volume]
    /// The downloaded macOS runner.
    public var installBytes: Int64
    public var logsBytes: Int64
    public init(engine: Bool, volumes: [Volume], installBytes: Int64, logsBytes: Int64) {
        self.engine = engine; self.volumes = volumes; self.installBytes = installBytes; self.logsBytes = logsBytes
    }
}

public enum RunnerCache {
    public static let prefix = "noodle-runner-cache-"

    public static func volume(repo: String) -> String { RunnerPin.cacheVolume(repo: repo) }

    /// `owner/repo` back from a volume name. GitHub owners have no `_`, so the first one is the slash.
    public static func repo(fromVolume name: String) -> String? {
        guard name.hasPrefix(prefix), let cut = name.dropFirst(prefix.count).firstIndex(of: "_") else { return nil }
        var rest = name.dropFirst(prefix.count)
        rest.replaceSubrange(cut...cut, with: "/")
        return RunnerStore.validRepo(String(rest)) ? String(rest) : nil
    }

    /// Nil when the repo's cache may be removed, else why not: a live job of that repo is using it.
    public static func clearRefusal(repo: String, state: RunnerState, helperActive: Bool) -> String? {
        guard helperActive, !state.running.isEmpty else { return nil }
        // Older state files have no runningRepos: any live runner might be this repo's.
        let busy = state.runningRepos.map { $0.contains { $0.lowercased() == repo.lowercased() } } ?? true
        return busy ? "\(repo) has a job running; clear its cache after the job ends." : nil
    }
}
