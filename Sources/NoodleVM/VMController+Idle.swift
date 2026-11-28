import Foundation
import OSLog
import NoodleCore

extension VMController {
    // MARK: activity / idle

    /// Mark the daemon as doing something. Cheap; call on every API request that touches the VM.
    public func noteActivity() {
        lastActivity = .now
        reclaimDue = true
        if balloonInflated, state == .running { deflateBalloon() }
        // An armed idle timer re-checks `lastActivity` when it fires, so a stream open only arms a timer that is not armed yet.
        if state == .running, timer?.isArmed != true { armTimer() }
    }

    /// True while containers run or long operations (pulls, streams) are in flight. Busy VMs never sleep.
    public func setBusy(_ value: Bool) {
        guard busy != value else { return }
        busy = value
        lastActivity = .now
        // Containers starting or exiting change guest memory either way.
        reclaimDue = true
        if state == .running { armTimer() }
    }

    func armTimer() {
        guard state == .running else { disarmTimer(); return }
        let timer = self.timer ?? ReusableTimer { [weak self] in
            guard let self else { return }
            Task { await self.timerFired() }
        }
        self.timer = timer
        timerIsBusy = busy
        if busy {
            // Containers are running. Reclaim guest memory once the VM has been quiet, then look once more after two
            // minutes if that found cache. With nothing changed no timer is armed at all.
            let now = ContinuousClock.now
            if let wait = Self.busyWait(now: now, reclaimDue: reclaimDue, lastActivity: lastActivity, notBefore: reclaimNotBefore,
                                        secondLookAt: secondLookAt, inflated: balloonInflated, quietChecks: quietChecks) {
                timer.arm(after: max(.seconds(1), wait), leeway: .seconds(5))
            } else {
                timer.disarm()
            }
        } else {
            // No containers: hand memory back after the quiet window, before the VM gets to sleep.
            let idleFor = Duration.seconds(settings.idleSleepSeconds)
            let wait = Self.idleWait(reclaimDue: reclaimDue, idleSleep: idleFor)
            let remaining = max(.seconds(1), wait - (ContinuousClock.now - lastActivity))
            timer.arm(after: remaining, leeway: .seconds(max(1, settings.idleSleepSeconds / 10)))
        }
    }

    func disarmTimer() { timer?.disarm() }

    private func timerFired() async {
        if timerIsBusy { await busyTick() } else { await idleTick() }
    }

    private func busyTick() async {
        guard state == .running, busy else { return }
        let now = ContinuousClock.now
        if reclaimDue, now - lastActivity < Self.reclaimQuiet - .seconds(1) || now < reclaimNotBefore - .seconds(1) { armTimer(); return }
        // Containers can work for minutes without one API call. Shrinking the guest then drops the files they are
        // reading and stalls them, so a busy guest keeps its memory and the reclaim waits.
        if await guestIsBusy() == true {
            if balloonInflated { deflateBalloon(); log.info("guest busy without API calls, balloon deflated") }
            reclaimDue = true
            reclaimNotBefore = .now + Self.busyRecheck
            quietChecks = 0
            armTimer()
            return
        }
        if reclaimDue || secondLookAt.map({ ContinuousClock.now >= $0 - .seconds(1) }) == true {
            let since = lastActivity
            reclaimWorked = await reclaimMemory()
            secondLookAt = reclaimWorked ? .now + .seconds(120) : nil
            quietChecks = 0
            // A call that landed during the reclaim keeps its own reclaim pending.
            if lastActivity == since { reclaimDue = false }
        } else {
            quietChecks += 1
        }
        armTimer()
    }

    /// Guest CPU over one second. Nil when the guest does not report it.
    func guestIsBusy() async -> Bool? {
        guard let first = await hooks.cpuTicks() else { return nil }
        try? await Task.sleep(for: .seconds(1))
        guard let second = await hooks.cpuTicks() else { return nil }
        return Self.guestBusy(from: first, to: second)
    }

    nonisolated static func guestBusy(from a: (busy: UInt64, total: UInt64), to b: (busy: UInt64, total: UInt64)) -> Bool {
        guard b.total > a.total, b.busy >= a.busy else { return false }
        return (b.busy - a.busy) * busyCPUShare >= b.total - a.total
    }

    /// When the busy timer fires next, or nil for no timer. A reclaim owed waits for the quiet window and any
    /// postponement; an inflated balloon is re-checked at 30 s, then every 60 s, so a job that starts without an API call thrashes at most a minute.
    nonisolated static func busyWait(now: ContinuousClock.Instant, reclaimDue: Bool, lastActivity: ContinuousClock.Instant,
                                     notBefore: ContinuousClock.Instant, secondLookAt: ContinuousClock.Instant?,
                                     inflated: Bool, quietChecks: Int) -> Duration? {
        if reclaimDue { return max(reclaimQuiet - (now - lastActivity), notBefore - now) }
        var wait = secondLookAt.map { $0 - now }
        if inflated {
            let check = quietChecks == 0 ? busyRecheck : inflatedCheckMax
            wait = min(wait ?? check, check)
        }
        return wait
    }

    private func idleTick() async {
        guard state == .running, !busy else { return }
        let elapsed = ContinuousClock.now - lastActivity
        if elapsed >= .seconds(settings.idleSleepSeconds) - .seconds(1) {
            log.info("idle for \(self.settings.idleSleepSeconds)s, sleeping VM")
            await sleepNow()
        } else if reclaimDue, elapsed >= Self.reclaimQuiet - .seconds(1) {
            // The reclaim's guest call is not activity, so the idle-sleep clock keeps running from `since`.
            let since = lastActivity
            _ = await reclaimMemory()
            if lastActivity == since { reclaimDue = false }
            armTimer()
        } else {
            armTimer()
        }
    }

    // MARK: balloon

    /// Inflate the balloon down to what the guest uses plus headroom; any API call deflates it again.
    /// Returns true when the guest held enough cache that one more look later is worth it.
    private func reclaimMemory() async -> Bool {
        guard host != nil else { return false }
        let plan = await reclaimPlan()
        // No await since `reclaimPlan` checked the epoch, so `host` is the VM the guest answered for.
        guard let target = plan.target, let host, target < host.configuredMemory else { return plan.again }
        host.setBalloonTarget(bytes: target)
        balloonInflated = true
        log.debug("balloon target \(target >> 20) MiB")
        return plan.again
    }

    /// Ask the guest, then pick a balloon target. No target when the guest did not report its use, or when activity or a
    /// reboot happened during the call: that answer is stale and a container start may need the memory.
    func reclaimPlan() async -> (target: UInt64?, again: Bool) {
        let since = lastActivity, epoch = bootEpoch
        let hint = await hooks.balloonHint()
        guard lastActivity == since, bootEpoch == epoch else { return (nil, false) }
        let again = Self.worthReclaiming(cache: hint.cache)
        guard let used = hint.used else {
            log.notice("balloon skipped: the guest did not report its memory use")
            return (nil, again)
        }
        return (Self.balloonTarget(workingSet: used), again)
    }

    /// With no containers running, a reclaim owed comes before idle sleep when the quiet window is shorter.
    nonisolated static func idleWait(reclaimDue: Bool, idleSleep: Duration) -> Duration {
        reclaimDue ? min(reclaimQuiet, idleSleep) : idleSleep
    }

    /// Whether to look again in two minutes: the drop found 32 MiB or more of cache, or the size is unknown.
    /// A small cache means nothing new was dirtied, so nothing is armed until the next activity.
    nonisolated static func worthReclaiming(cache: UInt64?) -> Bool {
        guard let cache else { return true }
        return cache >= reclaimMinCache
    }

    /// Guest use plus a quarter and 256 MiB, at least 512 MiB. The figure comes from the guest, so this saturates.
    nonisolated static func balloonTarget(workingSet used: UInt64) -> UInt64 {
        let (a, o1) = used.addingReportingOverflow(used / 4)
        let (b, o2) = a.addingReportingOverflow(256 << 20)
        return o1 || o2 ? .max : max(UInt64(512) << 20, b)
    }

    func deflateBalloon() {
        quietChecks = 0
        host?.setBalloonTarget(bytes: host?.configuredMemory ?? 0)
        balloonInflated = false
    }
}
