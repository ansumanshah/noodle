import Testing
import NoodleCore

// Resume decisions for interrupted blob downloads: where to continue from, and whether a curl-style
// exit code is retried, restarted, or failed. Pure logic, so every case runs without network access.

@Suite struct DownloadResumeTests {
    // MARK: next

    @Test(arguments: [
        (UInt64(0), UInt64(100), DownloadResume.Step.fetch(from: 0)),
        (UInt64(40), UInt64(100), .fetch(from: 40)),
        (UInt64(100), UInt64(100), .verify),
        (UInt64(101), UInt64(100), .restart),
        (UInt64(0), UInt64(0), .fetch(from: 0)),
        (UInt64(50), UInt64(0), .fetch(from: 50)),
    ])
    func nextStep(partial: UInt64, total: UInt64, expected: DownloadResume.Step) {
        #expect(DownloadResume.next(partialBytes: partial, totalBytes: total) == expected)
    }

    // MARK: after: success and restart

    @Test func successIsDoneAndClearsStalls() {
        let r = DownloadResume.after(code: 0, before: 0, after: 100, stalls: 3)
        #expect(r.outcome == .done)
        #expect(r.stalls == 0)
    }

    @Test func restartCodeCountsAStall() {
        let r = DownloadResume.after(code: 33, before: 0, after: 0, stalls: 0)
        #expect(r.outcome == .restart)
        #expect(r.stalls == 1)
    }

    @Test func restartCodeFailsAtStallLimit() {
        let r = DownloadResume.after(code: 33, before: 0, after: 0, stalls: 4)
        #expect(r.outcome == .fail)
        #expect(r.stalls == 5)
    }

    // MARK: after: permanent failures

    @Test(arguments: [1, 2, 3, 22, 23, 26, 27, 51, 60, 77] as [Int32])
    func permanentCodeFailsKeepingStalls(code: Int32) {
        let r = DownloadResume.after(code: code, before: 0, after: 0, stalls: 2)
        #expect(r.outcome == .fail)
        #expect(r.stalls == 2)
    }

    // MARK: after: transient failures

    @Test(arguments: [7, 18, 28, 56] as [Int32])
    func transientCodeWithProgressRetriesAndResetsStalls(code: Int32) {
        let r = DownloadResume.after(code: code, before: 0, after: 10, stalls: 3)
        #expect(r.outcome == .retry(afterSeconds: 1))
        #expect(r.stalls == 0)
    }

    @Test func transientNoProgressFirstStallBacksOffTwoSeconds() {
        let r = DownloadResume.after(code: 28, before: 10, after: 10, stalls: 0)
        #expect(r.outcome == .retry(afterSeconds: 2))
        #expect(r.stalls == 1)
    }

    @Test func transientNoProgressBackoffDoublesPerStall() {
        let r = DownloadResume.after(code: 28, before: 10, after: 10, stalls: 3)
        #expect(r.outcome == .retry(afterSeconds: 16))
        #expect(r.stalls == 4)
    }

    @Test func transientNoProgressFailsAtStallLimit() {
        let r = DownloadResume.after(code: 28, before: 10, after: 10, stalls: 4)
        #expect(r.outcome == .fail)
        #expect(r.stalls == 5)
    }

    // MARK: simulated loops

    @Test func fiveStalledAttemptsFailOnTheFifth() {
        var stalls = 0
        var outcomes: [DownloadResume.Outcome] = []
        for _ in 0..<5 {
            let r = DownloadResume.after(code: 28, before: 10, after: 10, stalls: stalls)
            outcomes.append(r.outcome)
            stalls = r.stalls
        }
        #expect(outcomes.prefix(4).allSatisfy { if case .retry = $0 { true } else { false } })
        #expect(outcomes.last == .fail)
    }

    @Test func progressBetweenStallsPreventsFailure() {
        var stalls = 0
        var outcomes: [DownloadResume.Outcome] = []
        // Four stalls, one attempt that makes progress, then four more stalls.
        let attempts: [(before: UInt64, after: UInt64)] = [
            (10, 10), (10, 10), (10, 10), (10, 10), (10, 20),
            (20, 20), (20, 20), (20, 20), (20, 20),
        ]
        for attempt in attempts {
            let r = DownloadResume.after(code: 28, before: attempt.before, after: attempt.after, stalls: stalls)
            outcomes.append(r.outcome)
            stalls = r.stalls
        }
        #expect(!outcomes.contains(.fail))
        #expect(outcomes[4] == .retry(afterSeconds: 1))
    }
}
