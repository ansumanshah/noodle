import Foundation

/// One repo's need for one kind of runner this tick, as the helper gathered it from GitHub.
public struct RunnerDemand: Equatable, Sendable {
    public var repo: String
    public var kind: RunnerKind
    /// Jobs of this kind waiting on GitHub.
    public var queued: Int
    /// A job ended lately and nothing of ours runs: keep one runner ready for the next push.
    public var warm: Bool
    /// Our own runners of this kind that can still take a job: starting, or listed idle.
    public var covered: Int
    /// Our own live runners of this kind.
    public var own: Int
    /// Held back this tick (a hold, the engine down, starts paused, a public repo): nothing starts, the two-poll count
    /// starts over, and its runners stay while it has queued jobs.
    public var blocked: Bool
    public init(repo: String, kind: RunnerKind, queued: Int, warm: Bool = false, covered: Int = 0, own: Int = 0, blocked: Bool = false) {
        self.repo = repo; self.kind = kind; self.queued = queued; self.warm = warm; self.covered = covered; self.own = own
        self.blocked = blocked
    }
    public var key: String { repo + "|" + kind.rawValue }
}

/// A live runner of the helper.
public struct RunnerSlot: Equatable, Sendable {
    public var name: String, repo: String, kind: RunnerKind
    public var idle: Bool
    /// Seconds since it started.
    public var age: TimeInterval
    public init(name: String, repo: String, kind: RunnerKind, idle: Bool, age: TimeInterval) {
        self.name = name; self.repo = repo; self.kind = kind; self.idle = idle; self.age = age
    }
}

public struct RunnerTickPlan: Equatable, Sendable {
    public struct Eviction: Equatable, Sendable {
        /// The idle runner to end, and the demand key whose start needs its slot.
        public var name: String, forKey: String
    }
    public var evictions: [Eviction] = []
    /// Runners to start, by demand key.
    public var starts: [String: Int] = [:]
}

/// The decision of one helper tick across every repo.
public enum RunnerTick {
    /// A runner younger than this may be about to take a job GitHub has not shown it yet.
    public static let settle: TimeInterval = 90

    /// Queued jobs go first, the repo with the fewest own runners and then the longest wait since its last start
    /// (`RunnerPlanner.started`, called by the caller after a runner really started) first, so a repo with a backlog cannot keep a contested slot. A start follows the two-poll rule as if a settled
    /// idle runner of a repo with nothing queued had given way; only then is that runner ended. A warm start never
    /// takes the last free slot while a queued job of that kind is uncovered.
    public static func plan(_ demands: [RunnerDemand], runners: [RunnerSlot], planner: inout RunnerPlanner) -> RunnerTickPlan {
        planner.ticks += 1
        planner.keep(keys: Set(demands.map(\.key)))
        var plan = RunnerTickPlan()
        for kind in RunnerKind.allCases {
            let mine = demands.filter { $0.kind == kind }
            var alive = runners.filter { $0.kind == kind }.count, uncovered = false
            let waiting = Set(mine.filter { $0.queued > 0 }.map(\.repo))
            var victims = runners.filter { $0.kind == kind && $0.idle && $0.age >= settle && !waiting.contains($0.repo) }
            let last = planner.lastStart
            let order = { (i: Int, d: RunnerDemand) in (d.own, last[d.key] ?? -1, i) }
            let queued = mine.enumerated().filter { $0.element.queued > 0 && !$0.element.blocked }
                .sorted { order($0.offset, $0.element) < order($1.offset, $1.element) }.map(\.element)
            for d in queued {
                let free = max(0, kind.cap - alive)
                let theirs = victims.filter { $0.repo != d.repo }
                let reclaim = min(theirs.count, max(0, d.queued - d.covered - free))
                let n = planner.startCount(key: d.key, queued: d.queued, covered: d.covered, alive: alive - reclaim, kind: kind,
                                           fresh: d.own == 0)
                let evict = theirs.prefix(max(0, n - free)).map(\.name)
                plan.evictions += evict.map { .init(name: $0, forKey: d.key) }
                victims.removeAll { evict.contains($0.name) }
                if n > 0 { plan.starts[d.key] = n }
                alive += n - evict.count
                if d.queued > d.covered + n { uncovered = true }
            }
            for d in mine where d.queued == 0 || d.blocked {
                // Nothing queued, or held back: the next shortfall is a new one and waits its poll.
                planner.forget(key: d.key)
                if !d.blocked, d.warm, d.own == 0, alive + (uncovered ? 1 : 0) < kind.cap { plan.starts[d.key] = 1; alive += 1 }
            }
        }
        return plan
    }

    /// Ends each planned eviction through `remove`: GitHub's delete, which refuses a runner that took a job meanwhile.
    /// A refused one stays and the start it was for is dropped. Returns the names removed.
    public static func evict(_ plan: inout RunnerTickPlan, remove: (RunnerTickPlan.Eviction) -> Bool) -> [String] {
        var removed: [String] = []
        for e in plan.evictions {
            if remove(e) { removed.append(e.name); continue }
            let left = (plan.starts[e.forKey] ?? 0) - 1
            plan.starts[e.forKey] = left > 0 ? left : nil
        }
        plan.evictions = []
        return removed
    }
}
