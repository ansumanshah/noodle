import Foundation
import Testing
@testable import NoodleCore

private func tempStore() throws -> RunnerStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("runner-history-\(UUID().uuidString)")
    let store = RunnerStore(paths: NoodlePaths(root: root))
    try FileManager.default.createDirectory(at: store.logDirectory, withIntermediateDirectories: true)
    return store
}

private func job(_ n: Int, log: String = "noodle-linux-a.log") -> RunnerJobRecord {
    RunnerJobRecord(repo: "o/r", name: "j\(n)", url: "u", conclusion: "success", at: Date(timeIntervalSince1970: Double(n)),
                    kind: .linux, seconds: n, log: log)
}

@Suite struct RunnerHistoryTests {
    @Test func historyIsNewestFirstAndCapped() {
        var s = RunnerState()
        for n in 0..<60 { s.record(job(n)) }
        #expect(s.history?.count == RunnerState.historyLimit)
        #expect(s.history?.first?.name == "j59" && s.history?.last?.name == "j10")
    }

    @Test func oldFilesStillDecode() throws {
        let repos = try JSONDecoder().decode([RunnerRepo].self, from: Data(#"[{"repo":"o/r","macos":false}]"#.utf8))
        #expect(repos[0].isEnabled && repos[0].allowPublic == nil)
        let state = try JSONDecoder().decode(RunnerState.self, from: Data(#"{"running":[],"awake":false,"lastJobs":{}}"#.utf8))
        #expect(state.history == nil)
        // Nil fields stay out of the file.
        #expect(!String(decoding: try JSONEncoder().encode(RunnerRepo(repo: "o/r", macos: false)), as: UTF8.self).contains("enabled"))
    }

    @Test func logTailStaysInsideTheLogsFolder() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try Data("one\ntwo\nthree\n".utf8).write(to: store.logDirectory.appendingPathComponent("noodle-linux-a.log"))
        try Data("secret".utf8).write(to: store.directory.appendingPathComponent("state.json"))
        #expect(store.logTail(for: job(1)) == "one\ntwo\nthree\n")
        #expect(store.logTail(for: job(1), maxBytes: 6) == "three\n")
        for bad in ["../state.json", "", "..", ".", "a/../../state.json", "/etc/hosts"] { #expect(store.logTail(for: job(1, log: bad)) == nil) }
        try FileManager.default.createSymbolicLink(at: store.logDirectory.appendingPathComponent("link.log"),
                                                   withDestinationURL: store.directory.appendingPathComponent("state.json"))
        #expect(store.logTail(for: job(1, log: "link.log")) == nil)
    }

    @Test func pruneKeepsTheNewestWithinTheCaps() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for n in 0..<6 {
            let url = store.logDirectory.appendingPathComponent("r\(n).log")
            try Data(repeating: 0, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + n))], ofItemAtPath: url.path)
        }
        func names() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: store.logDirectory.path)) ?? []) }
        store.pruneLogs(keep: 4, maxBytes: 10_000)
        #expect(names() == ["r5.log", "r4.log", "r3.log", "r2.log"])
        store.pruneLogs(keep: 4, maxBytes: 250)
        #expect(names() == ["r5.log", "r4.log"])
    }

    @Test func pruneNeverDeletesTheNewestOrARunningLog() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for n in 0..<3 {
            let url = store.logDirectory.appendingPathComponent("r\(n).log")
            try Data(repeating: 0, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + n))], ofItemAtPath: url.path)
        }
        store.pruneLogs(keep: 1, maxBytes: 10, running: ["r0.log"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: store.logDirectory.path)) == ["r2.log", "r0.log"])
    }

    @Test func aMissingRepoListIsEmptyAndABrokenOneIsNeverOverwritten() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(try store.loadRepos().isEmpty)
        let file = store.directory.appendingPathComponent("repos.json")
        try Data("[{\"repo\":\"o/a\",\"macos\":false},".utf8).write(to: file)  // cut short
        #expect(throws: RunnerStoreError.self) { try store.loadRepos() }
        #expect(throws: RunnerStoreError.self) { try store.updateRepos { $0.append(RunnerRepo(repo: "o/b", macos: false)) } }
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasSuffix("},"))
    }

    @Test func concurrentRepoUpdatesKeepEveryChange() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            _ = try? store.updateRepos { $0.append(RunnerRepo(repo: "o/r\(i)", macos: false)) }
        }
        #expect(try store.loadRepos().count == 20)
    }

    @Test func diskBytesCountsASingleFile() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let url = store.logDirectory.appendingPathComponent("a.log")
        let other = store.logDirectory.appendingPathComponent("b.log")
        try Data(repeating: 1, count: 10_000).write(to: url)
        try Data(repeating: 2, count: 200_000).write(to: other)
        let allocated = try #require(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        #expect(RunnerStore.diskBytes(url) == Int64(allocated))
        #expect(RunnerStore.diskBytes(url) >= 10_000 && RunnerStore.diskBytes(url) < 200_000)
        #expect(RunnerStore.diskBytes(store.logDirectory) == RunnerStore.diskBytes(url) + RunnerStore.diskBytes(other))
        #expect(RunnerStore.diskBytes(store.logDirectory.appendingPathComponent("missing.log")) == 0)
    }

    @Test func visibilityIsRecheckedAndCached() throws {
        var v = RunnerVisibility()
        var calls = 0, isPrivate = true
        let check: (String) throws -> Bool = { _ in calls += 1; return isPrivate }
        let repo = RunnerRepo(repo: "o/r", macos: false), t0 = Date(timeIntervalSince1970: 0)
        #expect(try v.refusal(repo, now: t0, isPrivate: check) == nil)
        isPrivate = false
        #expect(try v.refusal(repo, now: t0.addingTimeInterval(60), isPrivate: check) == nil)  // cached
        #expect(calls == 1)
        let why = try v.refusal(repo, now: t0.addingTimeInterval(RunnerVisibility.ttl + 1), isPrivate: check)
        #expect(calls == 2 && why?.contains("public now") == true && why?.contains("--allow-public") == true)
        // Allowed public repos are never asked about.
        var allowed = RunnerRepo(repo: "o/p", macos: false); allowed.allowPublic = true
        #expect(try v.refusal(allowed, isPrivate: check) == nil && calls == 2)
        // Errors are not cached, so the next poll asks again.
        #expect(throws: RunnerAPIError.network) { _ = try v.refusal(RunnerRepo(repo: "o/x", macos: false), isPrivate: { _ in throw RunnerAPIError.network }) }
        #expect(try v.refusal(RunnerRepo(repo: "o/x", macos: false), isPrivate: { _ in true }) == nil)
    }

    @Test func cacheVolumesMapBackAndClearingWaitsForLiveJobs() {
        #expect(RunnerCache.volume(repo: "acme/my_app") == "noodle-runner-cache-acme_my_app")
        #expect(RunnerCache.repo(fromVolume: "noodle-runner-cache-acme_my_app") == "acme/my_app")
        #expect(RunnerCache.repo(fromVolume: "noodle-runner-cache-noowner") == nil)
        #expect(RunnerCache.repo(fromVolume: "other-acme_app") == nil)
        var s = RunnerState()
        s.running = ["noodle-linux-a"]; s.runningRepos = ["Acme/App"]
        #expect(RunnerCache.clearRefusal(repo: "acme/app", state: s, helperActive: true) != nil)
        #expect(RunnerCache.clearRefusal(repo: "acme/other", state: s, helperActive: true) == nil)
        #expect(RunnerCache.clearRefusal(repo: "acme/app", state: s, helperActive: false) == nil)  // stale state
        s.runningRepos = nil
        #expect(RunnerCache.clearRefusal(repo: "acme/other", state: s, helperActive: true) != nil)  // old state: unknown repo
        s.running = []
        #expect(RunnerCache.clearRefusal(repo: "acme/app", state: s, helperActive: true) == nil)
    }
}
