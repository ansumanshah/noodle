import Foundation

/// What the helper learned about a finished runner. `job` is three-valued so a failed lookup is never read as "no job".
public struct RunnerExit: Sendable {
    public enum Job: Sendable { case took, none, unknown }
    public var kind: RunnerKind, repo: String, name: String
    public var seconds: TimeInterval
    public var status: Int32
    /// True when the helper ended this runner itself (idle, shutdown). The 6 h job limit is not a deliberate stop.
    public var stopped: Bool
    public var job: Job
    public var lastLine: String?
    public init(kind: RunnerKind, repo: String, name: String, seconds: TimeInterval, status: Int32, stopped: Bool, job: Job, lastLine: String?) {
        self.kind = kind; self.repo = repo; self.name = name; self.seconds = seconds; self.status = status
        self.stopped = stopped; self.job = job; self.lastLine = lastLine
    }

    /// A start failed when the runner, with the API confirming it took no job, exited with an error or died within `quick` seconds.
    public var isFailure: Bool { job == .none && !stopped && (status != 0 || seconds < RunnerCrashGuard.quick) }
    /// A start worked when the runner took a job, or the helper ended it on purpose after it registered.
    public var isSuccess: Bool { job == .took || stopped }
}

/// Runners that exit with an error, or die within seconds, without taking a job mean the engine or the runner is broken,
/// and every new start registers one more runner on GitHub. Each failed start delays the next one (30 s, 60 s, then 120 s)
/// and is remembered until a runner takes a job or is ended on purpose.
/// Kept per kind, not per repo: a VM that cannot start affects every repo.
/// Seconds on a clock that never steps with the wall clock and keeps counting while the Mac sleeps (CLOCK_MONOTONIC),
/// for intervals inside one helper process. Never persisted: it restarts at boot.
public enum RunnerClock {
    public static func now() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
}

public struct RunnerCrashGuard: Sendable {
    public static let quick: TimeInterval = 30
    public private(set) var failures: [RunnerKind: RunnerStartFailure] = [:]
    private var count: [RunnerKind: Int] = [:]
    private var retryAt: [RunnerKind: TimeInterval] = [:]  // RunnerClock

    public init(restoring saved: [String: RunnerStartFailure]? = nil, now: Date = Date()) {
        for f in RunnerStartFailure.active(saved, now: now) { failures[f.kind] = f }
    }

    public static func delay(afterFailures n: Int) -> TimeInterval { n <= 1 ? 30 : n == 2 ? 60 : 120 }

    /// Call exactly once per finished runner.
    public mutating func ended(_ e: RunnerExit, now: Date = Date(), uptime: TimeInterval = RunnerClock.now()) {
        if e.isSuccess { count[e.kind] = 0; retryAt[e.kind] = nil; failures[e.kind] = nil; return }
        guard e.isFailure else { return }
        failed(e.kind, repo: e.repo, reason: e.lastLine.flatMap(RunnerStartFailure.reason(fromLogLine:)), log: e.name + ".log", now: now, uptime: uptime)
    }

    /// A runner that could not be started at all (no docker CLI, no runner download, no work folder). There is no log.
    public mutating func failedToStart(_ kind: RunnerKind, repo: String, reason: String, now: Date = Date(),
                                       uptime: TimeInterval = RunnerClock.now()) {
        failed(kind, repo: repo, reason: RunnerStartFailure.reason(fromLogLine: reason), log: nil, now: now, uptime: uptime)
    }

    private mutating func failed(_ kind: RunnerKind, repo: String, reason: String?, log: String?, now: Date, uptime: TimeInterval) {
        expire(now: now)
        let n = count[kind, default: 0] + 1
        count[kind] = n
        retryAt[kind] = uptime + Self.delay(afterFailures: n)
        failures[kind] = RunnerStartFailure(kind: kind, repo: repo, at: now, reason: reason, log: log)
    }

    /// Forgets failures older than `RunnerStartFailure.lifetime`, so the next one waits 30 s again and the state file drops them.
    public mutating func expire(now: Date = Date()) {
        // Only a failure older than its lifetime: a clock set back must not clear a pause early.
        for (kind, f) in failures where now.timeIntervalSince(f.at) > RunnerStartFailure.lifetime {
            failures[kind] = nil; count[kind] = 0; retryAt[kind] = nil
        }
    }

    /// Why this kind waits, or nil when it may start.
    public func paused(_ kind: RunnerKind, uptime: TimeInterval = RunnerClock.now()) -> String? {
        guard let at = retryAt[kind], uptime < at, let f = failures[kind] else { return nil }
        let wait = Int((at - uptime).rounded(.up))
        return "\(f.kindName) runners keep failing to start" + (f.reason.map { ": \($0)" } ?? "") + ". Trying again in \(wait) s."
    }

    /// The failures as stored in the state file.
    public var stored: [String: RunnerStartFailure]? {
        failures.isEmpty ? nil : Dictionary(uniqueKeysWithValues: failures.map { ($0.key.rawValue, $0.value) })
    }
}
