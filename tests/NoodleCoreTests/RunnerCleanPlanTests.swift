import Foundation
import Testing
@testable import NoodleCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private func daysAgo(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-clean-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("work/a"), withIntermediateDirectories: true)
    return root
}

private func plan(_ root: URL, _ items: [RunnerCleanItem], busy: Set<String> = [], all: Bool = false, days: Int = 14) -> RunnerCleanPlan {
    RunnerCleanPlanner.plan(.init(root: root, items: items, busyRepos: busy, allReposBusy: all),
                            .init(olderThanDays: days, currentVersion: "2.0.0", now: now))
}

@Suite struct RunnerCleanPlanTests {
    @Test func ordersByTierAndRespectsCutoff() throws {
        let root = try fixture()
        let p = plan(root, [
            .init(tier: .repoCaches, kind: .volume, ref: "v-old", lastUsed: daysAgo(20), repo: "o/a"),
            .init(tier: .repoCaches, kind: .volume, ref: "v-new", lastUsed: daysAgo(3), repo: "o/b"),
            .init(tier: .repoCaches, kind: .volume, ref: "v-unknown", repo: "o/c"),
            .init(tier: .leftovers, kind: .folder, ref: root.appendingPathComponent("work/a").path),
        ])
        #expect(p.deletions.map(\.item.ref) == [root.appendingPathComponent("work/a").path, "v-old"])
        #expect(Set(p.skipped.map(\.item.ref)) == ["v-new", "v-unknown"])
    }

    @Test func busyRepoAndBusyItemAreSkipped() throws {
        let root = try fixture()
        let items: [RunnerCleanItem] = [
            .init(tier: .repoCaches, kind: .volume, ref: "v1", lastUsed: daysAgo(30), repo: "O/A"),
            .init(tier: .repoCaches, kind: .volume, ref: "v2", lastUsed: daysAgo(30), repo: "o/b"),
            .init(tier: .leftovers, kind: .container, ref: "c1", busy: true),
        ]
        let p = plan(root, items, busy: ["o/a"])
        #expect(p.deletions.map(\.item.ref) == ["v2"])
        #expect(p.skipped.count == 2)
        #expect(plan(root, items, all: true).deletions.map(\.item.ref).isEmpty)
    }

    @Test func currentRunnerVersionIsKept() throws {
        let root = try fixture()
        let p = plan(root, [
            .init(tier: .runnerDownloads, kind: .folder, ref: root.appendingPathComponent("work/a").path, version: "2.0.0"),
            .init(tier: .runnerDownloads, kind: .folder, ref: root.appendingPathComponent("work").path + "/../work/a", version: "1.0.0"),
        ])
        #expect(p.deletions.count == 1 && p.deletions[0].item.version == "1.0.0")
        #expect(p.skipped.first?.reason == "current runner version")
    }

    @Test func pathsOutsideRootOrThroughSymlinksAreRejected() throws {
        let root = try fixture(), outside = try fixture()
        let link = root.appendingPathComponent("work/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let p = plan(root, [
            .init(tier: .leftovers, kind: .folder, ref: outside.path),
            .init(tier: .leftovers, kind: .folder, ref: link.path),
            .init(tier: .leftovers, kind: .folder, ref: root.path),
            .init(tier: .leftovers, kind: .folder, ref: root.path + "/work/../../etc"),
        ])
        #expect(p.deletions.isEmpty && p.skipped.count == 4)
    }

    @Test func dryRunExecutorLeavesEveryFileInPlace() throws {
        let root = try fixture()
        let dir = root.appendingPathComponent("work/a")
        try Data("x".utf8).write(to: dir.appendingPathComponent("f"))
        let p = plan(root, [.init(tier: .leftovers, kind: .folder, ref: dir.path)])
        #expect(p.deletions.count == 1)
        let dry = RunnerCleanRules.execute(p, root: root, dryRun: true, external: { _ in Issue.record("external ran"); return true })
        #expect(dry.done.count == 1 && dry.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("f").path))
        let real = RunnerCleanRules.execute(p, root: root, dryRun: false, external: { _ in true })
        #expect(real.done.count == 1 && !FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func workFolderBusyRules() {
        let t0 = now
        func busy(touched: Date?, running: Set<String> = [], cwds: [String]? = []) -> Bool {
            RunnerCleanRules.folderBusy(path: "/r/work/job1", running: running, touched: touched, now: t0, grace: 600, processDirectories: cwds)
        }
        #expect(!busy(touched: t0.addingTimeInterval(-3600)))
        #expect(busy(touched: t0.addingTimeInterval(-60)))          // recent, even with the helper off
        #expect(busy(touched: nil))
        #expect(busy(touched: t0.addingTimeInterval(-3600), running: ["job1"]))
        #expect(busy(touched: t0.addingTimeInterval(-3600), cwds: ["/r/work/job1/_work/x"]))
        #expect(!busy(touched: t0.addingTimeInterval(-3600), cwds: ["/r/work/job10"]))
        #expect(busy(touched: t0.addingTimeInterval(-3600), cwds: nil))   // process list unreadable: assume busy
    }

    @Test func workFolderBusyResolvesSymlinks() throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("runner-clean-\(UUID().uuidString)/job1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let lsofPath = "/private" + dir.path + "/_work"  // lsof prints the resolved /private/tmp
        #expect(RunnerCleanRules.folderBusy(path: dir.path, running: [], touched: now.addingTimeInterval(-3600), now: now, grace: 600,
                                            processDirectories: [lsofPath]))
    }

    @Test func lsofListSkipsPidsNeverToSignal() throws {
        let out = "p0\nn/w/a\np1\nn/w/b\np4242\nn/w/c\np77\nn/w/d\n"
        let list = try #require(RunnerCleanRules.processDirectories(lsofOutput: out, code: 0, ownPID: 4242))
        #expect(list.map(\.pid) == [77])
        #expect(!RunnerCleanRules.signalable(1, ownPID: 9) && !RunnerCleanRules.signalable(9, ownPID: 9) && RunnerCleanRules.signalable(10, ownPID: 9))
    }

    @Test func lsofExitOneWithAListIsAList() {
        let out = "p77\nn/w/d\n"
        #expect(RunnerCleanRules.processDirectories(lsofOutput: out, code: 1, ownPID: 9)?.map(\.pid) == [77])
        #expect(RunnerCleanRules.processDirectories(lsofOutput: "", code: 0, ownPID: 9) == nil)
        #expect(RunnerCleanRules.processDirectories(lsofOutput: "", code: 1, ownPID: 9) == nil)
        for code: Int32 in [2, 124, 127] { #expect(RunnerCleanRules.processDirectories(lsofOutput: out, code: code, ownPID: 9) == nil) }
    }

    @Test func symlinkedWorkFolderDoesNotReachItsTarget() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("runner-sweep-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work"), elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("noodle-macos-a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("noodle-macos-link"), withDestinationURL: elsewhere)
        defer { try? FileManager.default.removeItem(at: root) }
        // lsof prints resolved paths.
        let processes: [(pid: Int32, path: String)] = [(10, "/private" + elsewhere.path), (11, "/private" + work.path + "/noodle-macos-a/_work"),
                                                       (12, "/private" + work.path + "/noodle-macos-ab")]
        #expect(RunnerCleanRules.pids(inWorkFolder: "noodle-macos-link", workDirectory: work.path, processes: processes).isEmpty)
        #expect(RunnerCleanRules.pids(inWorkFolder: "noodle-macos-a", workDirectory: work.path, processes: processes) == [11])
    }

    @Test func containerCandidates() {
        let running: Set<String> = ["noodle-linux-a"]
        #expect(!RunnerCleanRules.containerCandidate(name: "noodle-linux-a", status: "exited", running: running))
        #expect(!RunnerCleanRules.containerCandidate(name: "noodle-linux-b", status: "created", running: running))
        #expect(RunnerCleanRules.containerCandidate(name: "noodle-linux-b", status: "exited", running: running))
    }

    @Test func cacheWithoutALastJobHasNoLastUse() throws {
        let p = plan(try fixture(), [.init(tier: .repoCaches, kind: .volume, ref: "v", lastUsed: nil, repo: "o/a")])
        #expect(p.deletions.isEmpty && p.skipped.first?.reason == "last use unknown")
    }

    @Test func onlyPlainVersionImagesAreCandidates() throws {
        let root = try fixture()
        func image(_ tag: String) -> RunnerCleanItem { .init(tier: .runnerImages, kind: .image, ref: "i:" + tag, lastUsed: daysAgo(90), version: tag) }
        let p = plan(root, ["1.0.0", "2.0.0", "latest", "2.1", "2.0.0-rc1", "v1.0.0"].map(image))
        #expect(p.deletions.map(\.item.version) == ["1.0.0"])
    }

    @Test func reportTotalsPerTier() {
        let a = RunnerCleanItem(tier: .logs, kind: .folder, ref: "x", bytes: 5)
        let r = RunnerCleanReport(dryRun: true, deleted: [.init(item: a, reason: "r"), .init(item: a, reason: "r")], skipped: [], failed: [], leftAlone: [])
        #expect(r.tiers[1].bytes == 10 && r.totalBytes == 10 && r.tiers[0].items == 0 && r.engine)
    }

    @Test func runnerImagesCountEachIdOnceAndKeepUsedOnes() throws {
        let repo = "ghcr.io/actions/actions-runner"
        let items = RunnerCleanRules.runnerImageItems([
            (id: "sha:a", tags: ["\(repo):1.0.0", "\(repo):1.1.0"], bytes: 100, created: daysAgo(30)),
            (id: "sha:b", tags: ["\(repo):1.2.0"], bytes: 50, created: daysAgo(30)),
            (id: "sha:c", tags: ["\(repo):1.3.0", "mine:latest"], bytes: 70, created: daysAgo(30)),
        ], repository: repo, usedIDs: ["sha:b"], currentVersion: "2.0.0")
        #expect(items.map(\.bytes) == [100, 100, 50, 0])
        let p = plan(try fixture(), items)
        #expect(p.deletions.map(\.item.ref) == ["\(repo):1.0.0", "\(repo):1.1.0", "\(repo):1.3.0"])
        let kept = p.skipped.first(where: { $0.item.ref == "\(repo):1.2.0" })
        #expect(kept?.reason == "used by a container")
        #expect(RunnerCleanRules.runnerImageItems([(id: "sha:a", tags: ["\(repo):1.0.0"], bytes: 1, created: nil)], repository: repo,
                                                  usedIDs: nil).allSatisfy { $0.busy })
    }

    @Test func anImageCountsOnceAndOnlyWhenAllItsTagsGo() {
        let repo = "ghcr.io/actions/actions-runner"
        let items = RunnerCleanRules.runnerImageItems([(id: "sha:a", tags: ["\(repo):1.0.0", "\(repo):1.1.0"], bytes: 100, created: nil)],
                                                      repository: repo, usedIDs: [], currentVersion: "2.0.0")
        let steps = items.map { RunnerCleanStep(item: $0, reason: "old") }
        let all = RunnerCleanReport(dryRun: false, deleted: steps, skipped: [], failed: [], leftAlone: [])
        #expect(all.totalBytes == 100)
        let half = RunnerCleanReport(dryRun: false, deleted: [steps[0]], skipped: [], failed: [steps[1]], leftAlone: [])
        #expect(half.totalBytes == 0)
    }

    @Test func aStepAJobTookAfterPlanningIsKept() throws {
        let root = try fixture()
        let p = plan(root, [.init(tier: .leftovers, kind: .container, ref: "noodle-linux-1"), .init(tier: .leftovers, kind: .container, ref: "noodle-linux-2")])
        let r = RunnerCleanRules.execute(p, root: root, dryRun: false, stillFree: { $0.ref != "noodle-linux-1" }, external: { _ in true })
        #expect(r.done.map(\.item.ref) == ["noodle-linux-2"] && r.busy.map(\.item.ref) == ["noodle-linux-1"] && r.failed.isEmpty)
        #expect(r.busy.first?.reason == "in use by a running job")
    }
}
