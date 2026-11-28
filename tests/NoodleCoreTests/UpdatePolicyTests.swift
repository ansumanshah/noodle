import Foundation
import Testing
@testable import NoodleCore

@Suite struct UpdatePolicyTests {
    private struct FakeClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        mutating func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    @Test func offNeverSchedulesEvenWhenOverdue() {
        let clock = FakeClock()
        #expect(UpdatePolicy.nextCheck(automatic: false, lastCheck: nil, now: clock.now) == nil)
        #expect(UpdatePolicy.nextCheck(automatic: false, lastCheck: clock.now.addingTimeInterval(-100_000), now: clock.now) == nil)
    }

    @Test func onWithoutHistoryIsDueImmediately() {
        let clock = FakeClock()
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: nil, now: clock.now) == clock.now)
    }

    @Test func notDueUntilSixHoursThenDue() {
        var clock = FakeClock()
        let lastCheck = clock.now
        let deadline = lastCheck.addingTimeInterval(6 * 60 * 60)
        clock.advance(6 * 60 * 60 - 1)
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: lastCheck, now: clock.now) == deadline)
        clock.advance(1)
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: lastCheck, now: clock.now) == clock.now)
    }

    @Test func afterSleepChecksOnceWithoutCatchingUpMissedIntervals() {
        var clock = FakeClock()
        let lastCheck = clock.now
        clock.advance(3 * 24 * 60 * 60)
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: lastCheck, now: clock.now) == clock.now)
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: clock.now, now: clock.now) == clock.now.addingTimeInterval(6 * 60 * 60))
    }

    @Test func isDueFollowsTheSameIntervalWhenTheWindowOpens() {
        var clock = FakeClock()
        let last = clock.now
        #expect(!UpdatePolicy.isDue(automatic: false, lastCheck: nil, now: clock.now))
        #expect(UpdatePolicy.isDue(automatic: true, lastCheck: nil, now: clock.now))
        clock.advance(6 * 60 * 60 - 1)
        #expect(!UpdatePolicy.isDue(automatic: true, lastCheck: last, now: clock.now))
        clock.advance(1)
        #expect(UpdatePolicy.isDue(automatic: true, lastCheck: last, now: clock.now))
    }

    @Test func installWarningNamesTheRunningCount() {
        #expect(UpdateInstallWarning.message(running: 0) == nil)
        #expect(UpdateInstallWarning.message(running: 1)?.contains("1 running container will stop") == true)
        #expect(UpdateInstallWarning.message(running: 3)?.contains("3 running containers will stop") == true)
    }

    @Test func failedContainerQueryRequiresConfirmation() {
        let warning = UpdateInstallWarning.message(running: nil)
        #expect(warning != nil)
        #expect(warning?.contains("could not check") == true)
        #expect(warning?.contains("stops the engine") == true)
    }

    @Test func togglingOffThenOnKeepsTheLastCheckDeadline() {
        let clock = FakeClock()
        #expect(UpdatePolicy.nextCheck(automatic: false, lastCheck: clock.now, now: clock.now) == nil)
        #expect(UpdatePolicy.nextCheck(automatic: true, lastCheck: clock.now, now: clock.now) == clock.now.addingTimeInterval(6 * 60 * 60))
    }
}
