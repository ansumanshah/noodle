import Testing
@testable import NoodleVM

/// When the balloon runs and how far it inflates. The guest decides nothing: it reports cache and usage.
@Suite struct ReclaimPolicyTests {
    @Test func smallCacheIsNotWorthABalloon() {
        #expect(!VMController.worthReclaiming(cache: 0))
        #expect(!VMController.worthReclaiming(cache: (32 << 20) - 1))
    }

    @Test func largeCacheIsWorthIt() {
        #expect(VMController.worthReclaiming(cache: 32 << 20))
        #expect(VMController.worthReclaiming(cache: UInt64.max))
    }

    @Test func anOlderAgentThatReportsNothingStillGetsTheBalloon() {
        #expect(VMController.worthReclaiming(cache: nil))
    }

    @Test func quietWindowIsShortEnoughToActBeforeTheOldTick() {
        #expect(VMController.reclaimQuiet < .seconds(120))
        #expect(VMController.reclaimQuiet >= .seconds(5))
    }

    @Test func idleVMReclaimsBeforeItSleeps() {
        #expect(VMController.idleWait(reclaimDue: true, idleSleep: .seconds(60)) == VMController.reclaimQuiet)
        #expect(VMController.idleWait(reclaimDue: true, idleSleep: .seconds(5)) == .seconds(5))
        #expect(VMController.idleWait(reclaimDue: false, idleSleep: .seconds(60)) == .seconds(60))
    }

    @Test func balloonFloorKeepsHeadroomForStarts() {
        #expect(VMController.balloonTarget(workingSet: 0) == 512 << 20)
        #expect(VMController.balloonTarget(workingSet: 1 << 30) == (1 << 30) + (256 << 20) + (256 << 20))
        #expect(VMController.balloonTarget(workingSet: .max) == .max)
    }

    @Test func guestBusyNeedsFivePercentOfAllCPUs() {
        // 5 CPUs over one second at 100 Hz: 500 ticks. One busy core is 100.
        #expect(VMController.guestBusy(from: (1000, 10_000), to: (1100, 10_500)))
        #expect(VMController.guestBusy(from: (1000, 10_000), to: (1025, 10_500)))
        #expect(!VMController.guestBusy(from: (1000, 10_000), to: (1010, 10_500)))
        // A reboot resets the counters: never call that busy.
        #expect(!VMController.guestBusy(from: (1000, 10_000), to: (5, 50)))
        #expect(!VMController.guestBusy(from: (1000, 10_000), to: (1000, 10_000)))
    }

    @Test func busyWaitPostponesAndBacksOff() {
        let now = ContinuousClock.now
        // Owed: the later of the quiet window and a postponement.
        #expect(VMController.busyWait(now: now, reclaimDue: true, lastActivity: now, notBefore: now, secondLookAt: nil,
                                      inflated: false, quietChecks: 0) == .seconds(20))
        #expect(VMController.busyWait(now: now, reclaimDue: true, lastActivity: now - .seconds(60), notBefore: now + .seconds(30),
                                      secondLookAt: nil, inflated: false, quietChecks: 0) == .seconds(30))
        // Nothing owed, balloon down: no timer at all.
        #expect(VMController.busyWait(now: now, reclaimDue: false, lastActivity: now, notBefore: now, secondLookAt: nil,
                                      inflated: false, quietChecks: 0) == nil)
        // Inflated: 30 s, then every 60 s.
        #expect(VMController.busyWait(now: now, reclaimDue: false, lastActivity: now, notBefore: now, secondLookAt: nil,
                                      inflated: true, quietChecks: 0) == .seconds(30))
        #expect(VMController.busyWait(now: now, reclaimDue: false, lastActivity: now, notBefore: now, secondLookAt: nil,
                                      inflated: true, quietChecks: 1) == .seconds(60))
        #expect(VMController.busyWait(now: now, reclaimDue: false, lastActivity: now, notBefore: now, secondLookAt: nil,
                                      inflated: true, quietChecks: 9) == .seconds(60))
        // The second look comes first when it is sooner.
        #expect(VMController.busyWait(now: now, reclaimDue: false, lastActivity: now, notBefore: now, secondLookAt: now + .seconds(10),
                                      inflated: true, quietChecks: 3) == .seconds(10))
    }
}
