import Foundation
import Testing
@testable import NoodleCore

@Suite struct RunnerCrashGuardTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func exit(_ kind: RunnerKind = .linux, after: TimeInterval = 3, status: Int32 = 1, stopped: Bool = false,
                      job: RunnerExit.Job = .none, line: String? = "x") -> RunnerExit {
        RunnerExit(kind: kind, repo: "o/r", name: "n", seconds: after, status: status, stopped: stopped, job: job, lastLine: line)
    }

    @Test func failureRules() {
        #expect(exit(after: 100, status: 125).isFailure)
        #expect(exit(after: 3, status: 0).isFailure)
        #expect(!exit(after: 100, status: 0).isFailure)
        #expect(!exit(job: .took).isFailure && exit(job: .took).isSuccess)
        #expect(!exit(job: .unknown).isFailure && !exit(job: .unknown).isSuccess)
        #expect(!exit(after: 400, status: 15, stopped: true).isFailure && exit(after: 400, status: 15, stopped: true).isSuccess)
    }

    @Test func backoffGrowsThenStaysAtTwoMinutes() {
        #expect([1, 2, 3, 4, 9].map(RunnerCrashGuard.delay(afterFailures:)) == [30, 60, 120, 120, 120])
        var g = RunnerCrashGuard()
        g.ended(exit(), now: t0, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("Trying again in 30 s") == true)
        #expect(g.paused(.linux, uptime: 30) == nil)
        #expect(g.paused(.macos, uptime: 0) == nil)
        g.ended(exit(), now: t0, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("in 60 s") == true)
        g.ended(exit(), now: t0, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("in 120 s") == true)
    }

    @Test func slowContainerStartFailureCounts() {
        var g = RunnerCrashGuard()
        g.ended(exit(after: 120, status: 125, line: "the Noodle VM could not start: timeout"), now: t0, uptime: 0)
        #expect(g.failures[.linux]?.reason == "the Noodle VM could not start: timeout")
        #expect(g.failures[.linux]?.log == "n.log")
    }

    @Test func onlyAJobOrADeliberateStopClearsAFailure() {
        var g = RunnerCrashGuard()
        g.ended(exit(), now: t0, uptime: 0); g.ended(exit(), now: t0, uptime: 0)
        // Unknown lookups and clean long exits change nothing; a running child never reaches the guard at all.
        g.ended(exit(after: 100, status: 0, job: .unknown), now: t0, uptime: 0)
        g.ended(exit(after: 100, status: 0), now: t0, uptime: 0)
        #expect(g.failures[.linux] != nil && g.paused(.linux, uptime: 0)?.contains("in 120 s") == false)
        g.ended(exit(job: .took), now: t0, uptime: 0)
        #expect(g.failures.isEmpty && g.paused(.linux, uptime: 0) == nil)
        g.ended(exit(), now: t0, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("in 30 s") == true)
        g.ended(exit(after: 400, status: 15, stopped: true), now: t0, uptime: 0)
        #expect(g.failures.isEmpty)
    }

    @Test func failuresExpireAfterAnHour() {
        var g = RunnerCrashGuard()
        g.ended(exit(.macos), now: t0.addingTimeInterval(-7200))
        g.ended(exit(.linux), now: t0, uptime: 0)
        let stored = g.stored
        let later = t0.addingTimeInterval(60)
        #expect(RunnerStartFailure.active(stored, now: later).map(\.kind) == [.linux])
        #expect(RunnerStartFailure.active(stored, now: t0.addingTimeInterval(3601)).isEmpty)
        #expect(RunnerCrashGuard(restoring: stored, now: later).failures.keys.sorted { $0.rawValue < $1.rawValue } == [.linux])
        #expect(RunnerStartFailure.active(nil, now: t0).isEmpty)
    }

    @Test func aClockStepNeitherHidesNorPinsAFailure() {
        let f = RunnerStartFailure(kind: .linux, repo: "o/r", at: t0, reason: nil, log: nil)
        #expect(f.isActive(now: t0.addingTimeInterval(-120)))  // the clock stepped back two minutes
        #expect(!f.isActive(now: t0.addingTimeInterval(-86_400)))  // `at` a day ahead: expired, not immortal
        #expect(f.isActive(now: t0.addingTimeInterval(3600)) && !f.isActive(now: t0.addingTimeInterval(3601)))
    }

    @Test func reasonIsLastLineScrubbedAndTrimmed() {
        #expect(RunnerStartFailure.lastLine(of: "a\nb\n  \n\n") == "b")
        #expect(RunnerStartFailure.lastLine(of: "\n \n") == nil)
        #expect(RunnerStartFailure.lastLine(of: "docker: the VM could not start\n\nRun 'docker run --help' for more information\n") == "docker: the VM could not start")
        let long = String(repeating: "Ab1+", count: 20)
        #expect(RunnerStartFailure.reason(fromLogLine: "auth ghs_abcdEFGH1234 and github_pat_11AAA failed") == "auth [hidden] and [hidden] failed")
        #expect(RunnerStartFailure.reason(fromLogLine: "key:\(long)y end") == "key:[hidden] end")
        let wrapped = RunnerStartFailure.reason(fromLogLine: #"{"encoded_jit_config":"\#(long)","id":1}"#)
        #expect(wrapped == #"{"encoded_jit_config":"[hidden]","id":1}"#)
        #expect(RunnerStartFailure.reason(fromLogLine: "fetch https://user:pw@github.com/o/r failed") == "fetch https://github.com/o/r failed")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.\(String(repeating: "abcDEF-ghi_", count: 4))"
        #expect(RunnerStartFailure.reason(fromLogLine: "token \(jwt) bad") == "token [hidden].[hidden].[hidden] bad")
        let digest = String(repeating: "a1b2", count: 16)
        #expect(RunnerStartFailure.reason(fromLogLine: "pull alpine@sha256:\(digest) failed") == "pull alpine@sha256:[hidden] failed")
        let cut = RunnerStartFailure.reason(fromLogLine: String(repeating: "word ", count: 100))
        #expect(cut?.count == 203 && cut?.hasSuffix("...") == true)
        #expect(RunnerStartFailure.reason(fromLogLine: "   ") == nil)
    }

    @Test func stateRoundTripsAndOlderStateDecodes() throws {
        var g = RunnerCrashGuard(); g.ended(exit(), now: t0, uptime: 0)
        var state = RunnerState()
        state.startFailures = g.stored
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(RunnerState.self, from: enc.encode(state)) == state)
        let old = try dec.decode(RunnerState.self, from: Data(#"{"running":[],"awake":false,"lastJobs":{}}"#.utf8))
        #expect(old.startFailures == nil)
        let f = try #require(RunnerStartFailure.active(state.startFailures, now: t0).first)
        #expect(f.line(logDirectory: URL(fileURLWithPath: "/l")) == "Linux runners are failing to start: x. Log: /l/n.log")
    }

    @Test func doctorReportsEachStartFailure() {
        var g = RunnerCrashGuard(); g.ended(exit(line: "boom"), now: t0, uptime: 0)
        var p = RunnerDoctorProbes()
        #expect(!RunnerDoctor.findings(p).contains { $0.id.hasPrefix("start-failure") })
        p.startFailures = RunnerStartFailure.active(g.stored, now: t0)
        let f = RunnerDoctor.findings(p).first { $0.id == "start-failure-linux" }
        #expect(f?.level == .problem && f?.message.contains("boom") == true)
    }

    @Test func expiredFailureIsDroppedAndTheCountStartsAgain() {
        var g = RunnerCrashGuard()
        g.ended(exit(), now: t0, uptime: 0); g.ended(exit(), now: t0, uptime: 0); g.ended(exit(), now: t0, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("in 120 s") == true)
        let later = t0.addingTimeInterval(RunnerStartFailure.lifetime + 60)
        g.expire(now: later)
        #expect(g.failures.isEmpty && g.stored == nil)
        g.ended(exit(), now: later, uptime: 0)
        #expect(g.paused(.linux, uptime: 0)?.contains("in 30 s") == true)
    }

    @Test func aClockSetBackDoesNotEndAPause() {
        var g = RunnerCrashGuard()
        g.ended(exit(), now: t0, uptime: 0); g.ended(exit(), now: t0, uptime: 0); g.ended(exit(), now: t0, uptime: 0)
        g.expire(now: t0.addingTimeInterval(-1000))  // the failure looks to be in the future
        #expect(g.paused(.linux, uptime: 0)?.contains("in 120 s") == true)
        #expect(g.failures.keys.contains(.linux))
    }

    @Test func aStartThatNeverRanBacksOffWithoutALog() throws {
        var g = RunnerCrashGuard()
        g.failedToStart(.macos, repo: "o/r", reason: "download failed (curl 6)", now: t0, uptime: 0)
        #expect(g.paused(.macos, uptime: 0)?.contains("download failed (curl 6). Trying again in 30 s") == true)
        g.failedToStart(.macos, repo: "o/r", reason: "download failed (curl 6)", now: t0, uptime: 0)
        #expect(g.paused(.macos, uptime: 0)?.contains("in 60 s") == true)
        let f = try #require(RunnerStartFailure.active(g.stored, now: t0).first)
        #expect(f.log == nil && f.line(logDirectory: URL(fileURLWithPath: "/l")) == "macOS runners are failing to start: download failed (curl 6).")
    }

    @Test func standardBase64WithSlashesIsHiddenWhole() {
        let jit = "eyAiZm9vIjogImJhciIgfQ/+abc/DEF0123456789/xyzXYZ+abcdefghij=="
        #expect(RunnerStartFailure.reason(fromLogLine: "config \(jit) rejected") == "config [hidden] rejected")
    }

    @Test func pathsAndImageNamesStayReadable() {
        for line in ["open /Users/me/Library/Group-Containers/noodle-runners/work/noodle-macos-ab12cd34: no such file",
                     "pull ghcr.io/owner/noodle-runner-linux:1.2"] {
            #expect(RunnerStartFailure.reason(fromLogLine: line) == line.replacingOccurrences(of: "/Users/me", with: "/Users/<user>"))
        }
    }

    @Test func bearerAndUrlPasswordsAreRedacted() {
        let line = RunnerStartFailure.reason(fromLogLine: "Bearer abcdefgh12345 password=hunter2 https://user:pw@github.com/o/r") ?? ""
        #expect(!line.contains("abcdefgh12345") && !line.contains("hunter2") && !line.contains("user:pw"))
    }

    @Test func zeroBytesPrintAsNumber() {
        #expect(RunnerStore.sizeText(0) == "0 KB")
        #expect(RunnerStore.sizeText(2_000_000) == "2 MB")
    }
}
