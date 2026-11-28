import Foundation

/// One long-lived one-shot timer. Re-arming moves its deadline; disarming leaves no wakeup scheduled.
/// Replaces a Task plus timer per arm: arming is a single `schedule` call and allocates nothing.
final class ReusableTimer: @unchecked Sendable {
    private let source: DispatchSourceTimer
    private let lock = NSLock()
    private var armed = false

    /// `fire` runs on a utility queue each time the deadline passes, unless the timer was moved or disarmed first.
    init(fire: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let wasArmed = self.armed; self.armed = false; self.lock.unlock()
            if wasArmed { fire() }
        }
        source.schedule(deadline: .distantFuture, repeating: .never)
        source.resume()
    }

    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }

    func arm(after delay: Duration, leeway: Duration) {
        lock.lock(); armed = true; lock.unlock()
        source.schedule(deadline: .now() + delay.timeInterval, repeating: .never, leeway: .nanoseconds(Int(leeway.timeInterval * 1e9)))
    }

    func disarm() {
        lock.lock(); armed = false; lock.unlock()
        source.schedule(deadline: .distantFuture, repeating: .never)
    }

    deinit { source.cancel() }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
