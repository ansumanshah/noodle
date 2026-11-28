import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@Suite struct RunnerRowsTests {
    private func job(_ repo: String, _ name: String, ago: TimeInterval) -> RunnerJobRecord {
        RunnerJobRecord(repo: repo, name: name, url: "", conclusion: "success", at: Date(timeIntervalSince1970: 1_000_000 - ago),
                        kind: .linux, seconds: 0, log: "")
    }

    @Test func jobsKeepHistoryOrderAndFilterBySearch() {
        var state = RunnerState()
        #expect(RunnerRows.jobs(state, search: "").isEmpty)
        state.history = [job("acme/web", "test", ago: 1), job("acme/ios", "build", ago: 2), job("acme/web", "lint", ago: 3)]
        #expect(RunnerRows.jobs(state, search: "").map(\.name) == ["test", "build", "lint"])
        #expect(RunnerRows.jobs(state, search: "web").map(\.name) == ["test", "lint"])
        #expect(RunnerRows.jobs(state, search: "build").map(\.repo) == ["acme/ios"])
        #expect(Set(state.history!.map(RunnerRows.jobID)).count == 3)
    }

    @Test func durationAndLogCap() {
        #expect(RunnerRows.duration(94) == "1 min, 34 secs")
        #expect(RunnerRows.duration(-5) == "0 secs")
        #expect(RunnerRows.logLines(nil) == "No log was kept for this job.")
        let long = (1...1_000).map(String.init).joined(separator: "\n")
        let shown = RunnerRows.logLines(long, maxLines: 400)
        #expect(shown.split(separator: "\n").count == 400)
        #expect(shown.hasSuffix("1000") && shown.hasPrefix("601"))
    }

    @Test func clearRefusalFollowsLiveJobs() {
        let report = RunnerCacheReport(engine: true, volumes: [
            .init(repo: "acme/web", volume: "noodle-runner-cache-acme_web", bytes: 10),
            .init(repo: "acme/docs", volume: "noodle-runner-cache-acme_docs", bytes: 20),
            .init(repo: nil, volume: "noodle-runner-cache-odd", bytes: nil),
        ], installBytes: 0, logsBytes: 0)
        var state = RunnerState()
        state.running = ["acme/web: lint"]; state.runningRepos = ["acme/web"]
        let rows = RunnerRows.caches(report, state: state, helperActive: true)
        #expect(rows.map(\.volume) == ["noodle-runner-cache-acme_docs", "noodle-runner-cache-acme_web", "noodle-runner-cache-odd"])
        #expect(rows[0].refusal == nil)
        #expect(rows[1].refusal?.contains("has a job running") == true)
        #expect(rows[2].refusal?.contains("docker volume rm") == true)
        // Helper off: nothing runs, so every known repo may clear.
        #expect(RunnerRows.caches(report, state: state, helperActive: false).filter { $0.repo != nil }.allSatisfy { $0.refusal == nil })
        #expect(RunnerRows.size(nil) == "Unknown")
    }

    @Test func holdShowsOnlyWhileTheHelperRuns() {
        var state = RunnerState()
        #expect(RunnerRows.holdLine(state, on: true) == nil)
        state.hold = "low disk"
        #expect(RunnerRows.holdLine(state, on: true) == "Holding new jobs: low disk")
        #expect(RunnerRows.holdLine(state, on: false) == nil)
        state.hold = "Holding new jobs: this Mac is low on memory"   // the helper's own text keeps one lead-in
        #expect(RunnerRows.holdLine(state, on: true) == "Holding new jobs: this Mac is low on memory")
    }

    @Test func trustTags() {
        #expect(RunnerRows.trust(RunnerRepo(repo: "a/b", macos: false)).map(\.label) == ["Private only"])
        let open = RunnerRows.trust(RunnerRepo(repo: "a/b", macos: true, enabled: false, allowPublic: true))
        #expect(open.map(\.label) == ["Paused", "Public allowed", "macOS runs as you"])
        #expect(open.map(\.warning) == [false, true, true])
    }

    @Test func startFailuresAndCardStatusOnlyWhileOn() {
        var state = RunnerState()
        let logs = URL(fileURLWithPath: "/tmp/logs")
        #expect(RunnerRows.cardStatus(state, on: false) == ("Off", false))
        #expect(RunnerRows.cardStatus(state, on: true) == ("On", true))
        state.hold = "Holding new jobs: 8 GB free on the Noodle volume, needs 10 GB"
        #expect(RunnerRows.cardStatus(state, on: true) == ("Holding", false))
        state.startFailures = [
            "linux": RunnerStartFailure(kind: .linux, repo: "acme/web", at: Date(timeIntervalSince1970: 1), reason: "no image", log: "a.log"),
            "macos": RunnerStartFailure(kind: .macos, repo: "acme/ios", at: Date(timeIntervalSince1970: 2), reason: nil, log: nil),
        ]
        #expect(RunnerRows.cardStatus(state, on: true) == ("Failing", false))
        let lines = RunnerRows.startFailureLines(state, on: true, logDirectory: logs)
        #expect(lines.count == 2 && lines[0].hasPrefix("macOS") && lines[1].hasSuffix("Log: /tmp/logs/a.log"))
        #expect(RunnerRows.startFailureLines(state, on: false, logDirectory: logs).isEmpty)
    }
}
