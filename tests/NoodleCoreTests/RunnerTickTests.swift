import Testing
@testable import NoodleCore

@Suite struct RunnerTickTests {
    private func slot(_ name: String, _ repo: String, idle: Bool, age: Double = 600) -> RunnerSlot {
        RunnerSlot(name: name, repo: repo, kind: .linux, idle: idle, age: age)
    }

    /// A few ticks of the helper against a GitHub that behaves as the real one does:
    /// - a started runner is starting (not idle) until it has been up `up` seconds (two polls), and only then takes a job;
    /// - `covered` is computed as the helper does: idle, or younger than the settle window;
    /// - a taken job is still listed as queued for one more poll;
    /// - a refused delete means the victim took a job: it turns busy.
    /// Each tick ages every runner 10 s. `finishBusy`: a busy runner's job ends at the next tick, so slots free up.
    private struct Sim {
        static let up: Double = 20
        var runners: [RunnerSlot], busy: Set<String>, queued: [String: Int], kind: RunnerKind
        var warm: Set<String>, blocked: Set<String>, finishBusy: Bool
        var lag: [String: Int] = [:], planner = RunnerPlanner(), made = 0

        init(runners: [RunnerSlot], queued: [String: Int], kind: RunnerKind = .linux, warm: Set<String> = [], blocked: Set<String> = [],
             finishBusy: Bool = false) {
            self.runners = runners; busy = Set(runners.filter { !$0.idle }.map(\.name)); self.queued = queued; self.kind = kind
            self.warm = warm; self.blocked = blocked; self.finishBusy = finishBusy
        }

        mutating func tick(refuse: Set<String> = []) -> (evicted: [String], starts: [String: Int]) {
            if finishBusy { runners.removeAll { busy.contains($0.name) } }
            for i in runners.indices { runners[i].idle = runners[i].age >= Self.up && !busy.contains(runners[i].name) }
            let demands = queued.keys.sorted().map { repo in
                let own = runners.filter { $0.repo == repo }
                return RunnerDemand(repo: repo, kind: kind, queued: (queued[repo] ?? 0) + (lag[repo] ?? 0), warm: warm.contains(repo),
                                    covered: own.filter { $0.idle || $0.age < RunnerTick.settle }.count, own: own.count,
                                    blocked: blocked.contains(repo))
            }
            lag = [:]
            var plan = RunnerTick.plan(demands, runners: runners, planner: &planner)
            let evicted = RunnerTick.evict(&plan) { e in
                if refuse.contains(e.name) { busy.insert(e.name); return false }
                return true
            }
            runners.removeAll { evicted.contains($0.name) }
            for (key, n) in plan.starts {
                let repo = String(key.split(separator: "|")[0])
                for _ in 0..<n { made += 1; runners.append(RunnerSlot(name: repo.lowercased() + "-new\(made)", repo: repo, kind: kind, idle: false, age: 0)) }
                planner.started(key: key)
            }
            for r in runners where r.age >= Self.up && !busy.contains(r.name) && (queued[r.repo] ?? 0) > 0 {
                busy.insert(r.name); queued[r.repo]! -= 1; lag[r.repo, default: 0] += 1
            }
            for i in runners.indices { runners[i].age += 10 }
            return (evicted, plan.starts)
        }
    }

    /// Repo A: one busy runner and a second job queued. Repo B: an idle warm runner holding the other slot. Cap 2.
    @Test func aQueuedJobGetsAWarmRunnersSlotOnTheSecondTickAndKeepsIt() {
        var sim = Sim(runners: [slot("a1", "A", idle: false), slot("b1", "B", idle: true)], queued: ["A": 1, "B": 0])
        // Tick 1: the shortfall waits its poll; b1 stays.
        #expect(sim.tick() == ([], [:]))
        // Tick 2: b1 gives way and A starts in the same tick.
        #expect(sim.tick() == (["b1"], ["A|linux": 1]))
        // Ticks 3 and 4: B wants a warm runner again, but both slots are A's (the new one starting, then on its job).
        sim.warm = ["B"]
        #expect(sim.tick() == ([], [:]))
        #expect(sim.tick() == ([], [:]))
        // A job ends: the warm runner gets the free slot.
        sim.runners.removeAll { $0.name == "a1" }
        #expect(sim.tick() == ([], ["B|linux": 1]))
    }

    @Test func aRefusedEvictionKeepsTheRunnerAndDropsTheStart() {
        var sim = Sim(runners: [slot("a1", "A", idle: false), slot("b1", "B", idle: true)], queued: ["A": 1, "B": 0])
        _ = sim.tick()
        // b1 took a job meanwhile: GitHub refuses the delete, and b1 is busy from then on.
        #expect(sim.tick(refuse: ["b1"]) == ([], [:]))
        #expect(sim.runners.map(\.name) == ["a1", "b1"])
        #expect(sim.tick() == ([], [:]))  // a busy runner is never a victim
        // b1's job ends: A gets the free slot after its poll, with nothing ended.
        sim.runners.removeAll { $0.name == "b1" }
        #expect(sim.tick() == ([], [:]))
        #expect(sim.tick() == ([], ["A|linux": 1]))
    }

    /// GitHub still lists a job as queued for a poll after a runner took it: no idle runner is ended for it.
    @Test func aJobQueuedForOnePollEndsNothing() {
        var sim = Sim(runners: [slot("a1", "A", idle: false), slot("b1", "B", idle: true)], queued: ["A": 1, "B": 0])
        #expect(sim.tick() == ([], [:]))
        sim.queued["A"] = 0
        #expect(sim.tick() == ([], [:]))
        #expect(sim.runners.map(\.name) == ["a1", "b1"])
    }

    /// Two jobs queue for A while its one runner is busy and B's idle runner holds the other slot. Over the whole
    /// sequence, with starting runners and the extra poll of a taken job, b1 is the only runner ended and A gets one
    /// runner per job, never an extra one.
    @Test func startingRunnersAndLateListsCauseNoExtraStartOrEviction() {
        var sim = Sim(runners: [slot("a1", "A", idle: false), slot("b1", "B", idle: true)], queued: ["A": 2, "B": 0])
        var evicted: [String] = [], started = 0
        for _ in 0..<6 { let t = sim.tick(); evicted += t.evicted; started += t.starts.values.reduce(0, +) }
        #expect(evicted == ["b1"] && started == 1)
        sim.runners.removeAll { $0.name == "a1" }  // the first job ends: the second gets the slot
        for _ in 0..<12 { let t = sim.tick(); evicted += t.evicted; started += t.starts.values.reduce(0, +) }
        #expect(evicted == ["b1"] && started == 2)
        #expect(sim.queued["A"] == 0)
    }

    /// Each runner lives three ticks here (two starting, one on its job), so turns come every third tick.
    @Test func twoReposWithBacklogsTakeTurnsOnTheMacSlot() {
        var sim = Sim(runners: [], queued: ["A": 5, "B": 5], kind: .macos, finishBusy: true)
        let turns = (0..<12).map { _ in sim.tick().starts.keys.sorted() }.filter { !$0.isEmpty }
        #expect(turns == [["A|macos"], ["B|macos"], ["A|macos"], ["B|macos"]])
    }

    @Test func idleRunnersOfARepoWithNoDemandGiveWayOnlyToQueuedWork() {
        let idle = [slot("a1", "A", idle: true), slot("a2", "A", idle: true)]
        // No demand anywhere: nothing ends (the idle timeout ends them later).
        var none = Sim(runners: idle, queued: [:])
        #expect(none.tick() == ([], [:]))
        // B has a job and no runner of its own: one of A's runners gives way at once.
        var sim = Sim(runners: idle, queued: ["B": 1])
        #expect(sim.tick() == (["a1"], ["B|linux": 1]))
    }

    @Test func twoQueuedJobsEndTwoIdleRunnersInOneTick() {
        var sim = Sim(runners: [slot("b1", "B", idle: true), slot("b2", "B", idle: true)], queued: ["A": 2])
        #expect(sim.tick() == (["b1", "b2"], ["A|linux": 2]))
    }

    @Test func aBlockedRepoStartsItsPollOverAndKeepsItsRunners() {
        // A's shortfall waited one poll, then a hold blocks it: once free again it waits a poll anew.
        var sim = Sim(runners: [slot("a1", "A", idle: false)], queued: ["A": 2])
        #expect(sim.tick().starts.isEmpty)
        sim.blocked = ["A"]
        #expect(sim.tick().starts.isEmpty)
        sim.blocked = []
        #expect(sim.tick().starts.isEmpty)
        #expect(sim.tick().starts == ["A|linux": 1])
        // A blocked repo with jobs queued keeps its idle runner even when another repo needs the slot.
        var held = Sim(runners: [slot("a1", "A", idle: true), slot("c1", "C", idle: false)], queued: ["A": 1, "B": 1],
                       blocked: ["A"])
        #expect(held.tick() == ([], [:]))
    }

    /// A paused, removed or skipped repo has no demand: when it comes back, its shortfall waits a poll again.
    @Test func aRepoMissingFromATickStartsItsPollOver() {
        var sim = Sim(runners: [slot("a1", "A", idle: false)], queued: ["A": 2])
        #expect(sim.tick().starts.isEmpty)
        sim.queued = [:]
        #expect(sim.tick().starts.isEmpty)
        sim.queued = ["A": 2]
        #expect(sim.tick().starts.isEmpty)
        #expect(sim.tick().starts == ["A|linux": 1])
    }

    /// The order stamp moves only when the caller reports a real start.
    @Test func aFailedStartKeepsTheReposPlaceInLine() {
        var planner = RunnerPlanner()
        let demands = [RunnerDemand(repo: "A", kind: .macos, queued: 1), RunnerDemand(repo: "B", kind: .macos, queued: 1)]
        #expect(RunnerTick.plan(demands, runners: [], planner: &planner).starts == ["A|macos": 1])
        // A's start failed (not reported): A is still first.
        #expect(RunnerTick.plan(demands, runners: [], planner: &planner).starts == ["A|macos": 1])
        planner.started(key: "A|macos")
        #expect(RunnerTick.plan(demands, runners: [], planner: &planner).starts == ["B|macos": 1])
    }

    @Test func aWarmStartNeverTakesTheLastSlotFromAnUncoveredJob() {
        var planner = RunnerPlanner()
        // A's shortfall waits a poll (not fresh), so one slot stays free; B's warm runner must not take it.
        let demands = [RunnerDemand(repo: "B", kind: .linux, queued: 0, warm: true),
                       RunnerDemand(repo: "A", kind: .linux, queued: 2, covered: 0, own: 1)]
        let plan = RunnerTick.plan(demands, runners: [slot("a1", "A", idle: false)], planner: &planner)
        #expect(plan.starts["B|linux"] == nil)
        // With nothing queued anywhere, the warm runner starts.
        let calm = RunnerTick.plan([RunnerDemand(repo: "B", kind: .linux, queued: 0, warm: true)], runners: [slot("a1", "A", idle: false)],
                                   planner: &planner)
        #expect(calm.starts == ["B|linux": 1])
    }

    @Test func onlySettledIdleRunnersOfReposWithNothingQueuedGiveWay() {
        var planner = RunnerPlanner()
        let a = RunnerDemand(repo: "A", kind: .linux, queued: 1, own: 0)
        // Too young: it may be about to take a job GitHub has not shown yet.
        let young = RunnerTick.plan([a], runners: [slot("b1", "B", idle: true, age: 30), slot("c1", "C", idle: false)], planner: &planner)
        #expect(young.evictions.isEmpty && young.starts.isEmpty)
        // Its own repo has a job of that kind queued: it stays for that job.
        let wanted = RunnerTick.plan([a, RunnerDemand(repo: "B", kind: .linux, queued: 1, covered: 1, own: 1)],
                                     runners: [slot("b1", "B", idle: true), slot("c1", "C", idle: false)], planner: &planner)
        #expect(wanted.evictions.isEmpty)
        // A slot already free: nothing is ended.
        let free = RunnerTick.plan([a], runners: [slot("b1", "B", idle: true)], planner: &planner)
        #expect(free.evictions.isEmpty && free.starts == ["A|linux": 1])
    }
}
