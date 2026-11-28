import Foundation
import Testing
@testable import NoodleVM

@Suite struct StartRetryTests {
    private let invalid = NSError(domain: "VZErrorDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "The storage device attachment is invalid."])

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func recoversWhenDiskIsReleased() async throws {
        let calls = Counter(), seen = Counter()
        try await StartRetry().run(sleep: { _ in }, record: { _ in _ = seen.next() }) {
            if calls.next() < 4 { throw invalid }
        }
        #expect(calls.value == 4)
        #expect(seen.value == 3)
    }

    @Test func otherErrorsFailImmediately() async {
        let calls = Counter()
        do {
            try await StartRetry().run(sleep: { _ in }) { _ = calls.next(); throw VMError.missingAsset("kernel") }
            Issue.record("must throw")
        } catch { #expect("\(error)".contains("kernel")) }
        #expect(calls.value == 1)
    }

    @Test func giveUpKeepsEveryAttemptAsEvidence() async {
        let calls = Counter()
        // The wait blocks its thread: a Task.sleep can resume seconds late when parallel tests fill the pool.
        let policy = StartRetry(maxElapsed: .seconds(3), firstDelay: .milliseconds(10), maxDelay: .milliseconds(20))
        let t0 = ContinuousClock.now
        do {
            try await policy.run(sleep: { _ in usleep(10_000) }) { _ = calls.next(); throw invalid }
            Issue.record("must throw")
        } catch {
            let text = "\(error)"
            #expect(text.contains("stayed in use"))
            #expect(text.contains("#1 at"))
            #expect(text.contains("storage device attachment is invalid"))
        }
        #expect(calls.value >= 3)
        #expect(ContinuousClock.now - t0 < .seconds(10))
    }

    @Test func laterNonRetryableErrorMentionsEarlierAttachmentFailure() async {
        let calls = Counter()
        do {
            try await StartRetry().run(sleep: { _ in }) {
                if calls.next() == 1 { throw invalid }
                throw VMError.invalidConfiguration("kernel unreadable")
            }
            Issue.record("must throw")
        } catch {
            let text = "\(error)"
            #expect(text.contains("kernel unreadable"))
            #expect(text.contains("attachment is invalid"))
        }
    }
}
