import NoodleCore
import SwiftUI

/// The repo list and helper state shared by the Runners pages and the sidebar, so none reads the files while drawing.
@MainActor @Observable
final class RunnerRepoList {
    private(set) var items: [RunnerRepo] = []
    /// What the helper last wrote: live jobs, last jobs per repo, history.
    private(set) var state = RunnerState()
    /// Helper on/off and the jobs running now, read with the repos so the sidebar card and the pages agree.
    private(set) var on = false
    private(set) var jobs = 0
    private(set) var busy = false

    func reload(env: AppEnvironment) {
        let store = RunnerStore(paths: env.paths)
        let next = env.demo ? Self.demoRepos : store.repos()
        if next != items { items = next }
        let nextOn = env.demo ? true : store.helperActive()
        var nextState = env.demo ? Self.demoStateNow : store.state()
        // A helper that died leaves its last live jobs in the file; with no helper nothing is running.
        if !nextOn { nextState.running = []; nextState.runningRepos = nil }
        if nextState != state { state = nextState }
        if nextOn != on { on = nextOn }
        if state.running.count != jobs { jobs = state.running.count }
    }

    /// Start or stop the helper through the CLI, as the Overview switch does. Returns the CLI's error text, if any.
    func setOn(_ value: Bool, env: AppEnvironment) async -> String? {
        await run(["runners", value ? "start" : "stop"], env: env)
    }

    /// One CLI call that edits runner state, then a reload. Returns the CLI's error text, if any.
    func run(_ args: [String], env: AppEnvironment) async -> String? {
        busy = true
        defer { busy = false; reload(env: env) }
        let result = await CLI.run(args)
        return result.code == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Demo

    static let demoRepos = [
        RunnerRepo(repo: "acme/web", macos: false),
        RunnerRepo(repo: "acme/ios-app", macos: true),
        RunnerRepo(repo: "acme/docs", macos: false, allowPublic: true),
        RunnerRepo(repo: "acme/legacy-api", macos: false, enabled: false),
    ]

    /// Made once, so the job IDs (which include the end time) stay put between reloads.
    static let demoStateNow = demoState()

    /// Fixed offsets from now, so relative times read the same in every capture.
    static func demoState(now: Date = .now) -> RunnerState {
        func job(_ repo: String, _ name: String, _ conclusion: String?, ago: TimeInterval, _ seconds: Int, _ kind: RunnerKind = .linux) -> RunnerJobRecord {
            RunnerJobRecord(repo: repo, name: name, url: "https://github.com/\(repo)/actions", conclusion: conclusion,
                            at: now.addingTimeInterval(-ago), kind: kind, seconds: seconds, log: "demo-\(repo.replacingOccurrences(of: "/", with: "-"))-\(name).log")
        }
        var state = RunnerState()
        state.history = [
            job("acme/web", "test", "success", ago: 240, 94),
            job("acme/ios-app", "build-ios", "success", ago: 1_800, 412, .macos),
            job("acme/docs", "deploy-preview", "failure", ago: 5_400, 38),
            job("acme/web", "lint", "success", ago: 9_000, 21),
            job("acme/legacy-api", "integration", "cancelled", ago: 86_400, 600),
        ]
        for record in (state.history ?? []).reversed() {
            state.lastJobs[record.repo] = RunnerLastJob(name: record.name, url: record.url, conclusion: record.conclusion, at: record.at)
        }
        state.running = ["acme/web: lint"]; state.runningRepos = ["acme/web"]
        if !DemoFlags.healthy { state.hold = "Holding new jobs: 8 GB free on the Noodle volume, needs 10 GB" }
        return state
    }

    static let demoLog = """
    2026-11-23T09:41:02Z Runner name: 'noodle-acme-web-7f3a'
    2026-11-23T09:41:02Z Job test started on [self-hosted, noodle]
    2026-11-23T09:41:03Z Restoring cache volume noodle-runner-cache-acme_web (412 MB)
    2026-11-23T09:41:05Z Run actions/checkout@v5
    2026-11-23T09:41:06Z Run bun install --frozen-lockfile
    2026-11-23T09:41:08Z 812 packages installed from cache
    2026-11-23T09:42:31Z Run bun run test
    2026-11-23T09:42:34Z 214 pass, 0 fail
    2026-11-23T09:42:36Z Job test completed with result: Succeeded
    """

    static let demoCache = RunnerCacheReport(engine: true, volumes: [
        .init(repo: "acme/web", volume: "noodle-runner-cache-acme_web", bytes: 412 << 20),
        .init(repo: "acme/docs", volume: "noodle-runner-cache-acme_docs", bytes: 96 << 20),
        .init(repo: "acme/legacy-api", volume: "noodle-runner-cache-acme_legacy-api", bytes: 1_288 << 20),
    ], installBytes: 214 << 20, logsBytes: 3 << 20)
}
