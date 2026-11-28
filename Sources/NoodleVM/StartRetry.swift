import Foundation

/// Bounded retry for the one start failure that is expected to clear on its own: after a hard
/// kill of the daemon, Virtualization.framework's helper process can still hold the data disk
/// for a moment, so the next `VZVirtualMachine.start` reports "The storage device attachment is
/// invalid." Every other error fails immediately. Each failed attempt is kept verbatim so the
/// evidence survives into the log and the final error.
public struct StartRetry: Sendable {
    public struct Attempt: Sendable, Equatable {
        public var number: Int
        public var elapsedMs: Int
        public var error: String
    }

    public var maxElapsed: Duration
    public var firstDelay: Duration
    public var maxDelay: Duration

    public init(maxElapsed: Duration = .seconds(15), firstDelay: Duration = .milliseconds(100), maxDelay: Duration = .seconds(1)) {
        self.maxElapsed = maxElapsed
        self.firstDelay = firstDelay
        self.maxDelay = maxDelay
    }

    /// True for the transient disk-held failure only. Matches the text because the same
    /// VZErrorDomain code 2 also covers permanent configuration errors.
    public static func isAttachmentInvalid(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("storage device attachment is invalid")
    }

    /// Runs `body` until it succeeds, fails with a non-retryable error, or the time budget is
    /// spent. `record` receives each failed attempt as it happens. On exhaustion the thrown
    /// error lists every attempt.
    public func run(clock: ContinuousClock = ContinuousClock(),
                    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    record: @Sendable (Attempt) -> Void = { _ in },
                    body: @Sendable () async throws -> Void) async throws {
        let start = clock.now
        var delay = firstDelay
        var attempts: [Attempt] = []
        while true {
            do {
                try await body()
                return
            } catch {
                guard Self.isAttachmentInvalid(error) else {
                    if attempts.isEmpty { throw error }
                    throw VMError.startFailed("\(error) (after \(attempts.count) retries of: \(attempts[0].error))")
                }
                let elapsed = clock.now - start
                let attempt = Attempt(number: attempts.count + 1, elapsedMs: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000), error: "\(error)")
                attempts.append(attempt)
                record(attempt)
                if elapsed + delay >= maxElapsed {
                    let detail = attempts.map { "#\($0.number) at \($0.elapsedMs) ms: \($0.error)" }.joined(separator: "; ")
                    throw VMError.startFailed("data disk stayed in use for \(attempts.count) attempts over \(attempt.elapsedMs) ms: \(detail)")
                }
                try await sleep(delay)
                delay = min(delay * 2, maxDelay)
            }
        }
    }
}
