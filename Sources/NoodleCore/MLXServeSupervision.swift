import Foundation

/// Restart policy for an unexpectedly exited runtime: 1 s, 2 s, 4 s ... capped at 30 s, and give up on the
/// fifth crash within ten minutes. The caller passes the time, so tests need no clock.
public struct MLXServeCrashPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval)
        case giveUp
    }

    public static let window: TimeInterval = 600
    public static let limit = 5
    public static let maxDelay: TimeInterval = 30
    private var crashes: [Date] = []
    private let baseDelay: TimeInterval

    public init(baseDelay: TimeInterval = 1) { self.baseDelay = baseDelay }

    public mutating func recordCrash(at now: Date) -> Decision {
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.window } + [now]
        guard crashes.count < Self.limit else { return .giveUp }
        return .restart(after: min(Self.maxDelay, baseDelay * pow(2, Double(crashes.count - 1))))
    }
}

/// mlx-serve answers HTTP 400 with "GPU memory" in the message when its admission check refuses a request.
/// Only a shortfall that says what "is available" can pass once memory frees up; "even after freeing" the prefix
/// cache means the prompt can never fit, which is a different problem (start a new chat or a shorter prompt).
public enum LocalModelMemoryRefusal {
    public static let message = "This Mac is short on memory right now. Close some apps or try a smaller model."

    // shortcut: text match on mlx-serve errors.zig messages, replace with a typed code if the server adds one
    public static func matches(_ body: String) -> Bool {
        body.contains("GPU memory") && body.contains("is available") && !body.contains("even after freeing")
    }

    /// The friendly line plus the engine's own detail, or nil when the body is another error.
    public static func userMessage(for body: String) -> String? {
        guard matches(body) else { return nil }
        struct Reply: Decodable {
            struct Failure: Decodable { let message: String? }
            let error: Failure?
        }
        let detail = (try? JSONDecoder().decode(Reply.self, from: Data(body.utf8)))?.error?.message
            ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
        return message + "\n" + detail
    }
}
