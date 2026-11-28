import Darwin
import Foundation

public struct RunnerRepo: Codable, Equatable, Sendable {
    public var repo: String
    public var macos: Bool
    /// False while paused (`noodle runners pause`): the helper skips it. Nil means enabled, so older repos.json decodes.
    public var enabled: Bool?
    /// True only after `add --allow-public`: the helper keeps serving it even if GitHub says it is public. Nil means false.
    public var allowPublic: Bool?
    public var kinds: [RunnerKind] { macos ? [.linux, .macos] : [.linux] }
    public var isEnabled: Bool { enabled != false }
    public init(repo: String, macos: Bool, enabled: Bool? = nil, allowPublic: Bool? = nil) {
        self.repo = repo; self.macos = macos; self.enabled = enabled; self.allowPublic = allowPublic
    }
}

public struct RunnerLastJob: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var conclusion: String?
    public var at: Date
    public init(name: String, url: String, conclusion: String?, at: Date) {
        self.name = name; self.url = url; self.conclusion = conclusion; self.at = at
    }
}

/// Written only by the helper, read by the CLI and the app.
public struct RunnerState: Codable, Equatable, Sendable {
    public var message: String?
    /// Why new jobs wait (low disk or memory), nil when the helper takes jobs. Running jobs are never touched.
    public var hold: String?
    public var running: [String] = []
    /// The repo of each live runner, so the app can mark its row. Optional so older state files still decode.
    public var runningRepos: [String]?
    /// True while a job holds the sleep assertion.
    public var awake = false
    public var lastJobs: [String: RunnerLastJob] = [:]
    /// Finished jobs, newest first, at most `RunnerState.historyLimit`. Optional so older state files still decode.
    public var history: [RunnerJobRecord]?
    /// The last failed start per kind (`RunnerKind.rawValue`), removed once a start of that kind works. Optional so older state files still decode.
    public var startFailures: [String: RunnerStartFailure]?
    public init() {}
}

extension RunnerState {
    /// The state to publish this tick. The hold is part of it, so a hold appearing or clearing on its own is saved.
    public func publishing(message: String?, running: [String], runningRepos: [String], awake: Bool, hold: String?) -> RunnerState {
        var next = self
        next.message = message
        next.running = running
        next.runningRepos = runningRepos
        next.awake = awake
        next.hold = hold
        return next
    }
}

public enum RunnerStoreError: Error, LocalizedError, Equatable {
    case unreadable(String, String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let why): "cannot read the runner repo list \(path) (\(why)). Fix or remove the file; nothing was changed."
        }
    }
}

/// Repo list, helper state and the helper's lock, under `<root>/runners`. Foundation only, shared by CLI and app.
public struct RunnerStore: Sendable {
    public let directory: URL
    public init(paths: NoodlePaths) { directory = paths.root.appendingPathComponent("runners", isDirectory: true) }

    private var configFile: URL { directory.appendingPathComponent("repos.json") }
    private var stateFile: URL { directory.appendingPathComponent("state.json") }
    public var stopMarker: URL { directory.appendingPathComponent("stop") }
    public var lockFile: URL { directory.appendingPathComponent("helper.lock") }
    public var workDirectory: URL { directory.appendingPathComponent("work", isDirectory: true) }
    public var logDirectory: URL { directory.appendingPathComponent("logs", isDirectory: true) }

    public static func validRepo(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(ok.contains) }
    }

    /// `owner/repo` from a GitHub remote URL (https, ssh or scp form), or nil for any other host.
    public static func repo(fromRemote url: String) -> String? {
        var t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            if t.hasSuffix("/") { t.removeLast() }
            if t.hasSuffix(".git") { t.removeLast(4) }
            return validRepo(t) ? t : nil
        }
        return nil
    }

    /// For display only: an unreadable list shows as empty. Anything that writes uses `loadRepos` or `updateRepos`.
    public func repos() -> [RunnerRepo] { (try? loadRepos()) ?? [] }

    /// The repo list. A missing file is an empty list; a file that cannot be read or decoded throws, so nobody
    /// overwrites it with a shorter list.
    public func loadRepos() throws -> [RunnerRepo] {
        let data: Data
        do { data = try Data(contentsOf: configFile) } catch CocoaError.fileReadNoSuchFile { return [] } catch {
            throw RunnerStoreError.unreadable(configFile.path, error.localizedDescription)
        }
        do { return try JSONDecoder().decode([RunnerRepo].self, from: data) } catch {
            throw RunnerStoreError.unreadable(configFile.path, "not a valid repo list")
        }
    }

    public func saveRepos(_ repos: [RunnerRepo]) throws {
        try ensure()
        try JSONEncoder().encode(repos).write(to: configFile, options: .atomic)
    }

    /// Read, change and write the list under a lock, so two commands at once do not lose each other's change.
    /// Nothing is written when the list cannot be read or `change` throws.
    @discardableResult
    public func updateRepos<T>(_ change: (inout [RunnerRepo]) throws -> T) throws -> T {
        try ensure()
        let fd = open(directory.appendingPathComponent("repos.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RunnerStoreError.unreadable(configFile.path, "cannot open its lock file") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw RunnerStoreError.unreadable(configFile.path, "cannot lock it: " + String(cString: strerror(errno))) }
        }
        var repos = try loadRepos()
        let result = try change(&repos)
        try saveRepos(repos)
        return result
    }

    public func state() -> RunnerState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RunnerState.self, from: Data(contentsOf: stateFile))) ?? RunnerState()
    }

    public func saveState(_ state: RunnerState) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? ensure()
        if let data = try? encoder.encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }

    func ensure() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The lock, not a PID file, says whether a helper lives.
    public func helperActive() -> Bool {
        let fd = open(lockFile.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    /// Takes the lock for the life of the process. Nil when another helper holds it.
    public func acquireLock() -> Int32? {
        try? ensure()
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return nil
    }
}
