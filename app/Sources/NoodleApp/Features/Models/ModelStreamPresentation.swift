// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
// A cancellable one-shot scheduler makes paused streams flush too.
import Foundation

@MainActor
struct ModelStreamScheduler {
    typealias Cancel = @MainActor () -> Void
    var now: @MainActor () -> TimeInterval
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancel

    static var live: Self {
        Self(now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, action in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        })
    }
}

struct ModelStreamBuffer {
    static let interval: TimeInterval = 0.1
    private(set) var pending = ""
    private var lastPublication: TimeInterval?

    mutating func append(_ delta: String, now: TimeInterval) -> String? {
        guard !delta.isEmpty else { return nil }
        pending += delta
        guard let lastPublication, now - lastPublication < Self.interval else {
            return drain(now: now)
        }
        return nil
    }

    func delay(now: TimeInterval) -> TimeInterval {
        max(0, Self.interval - (now - (lastPublication ?? now)))
    }

    mutating func drain(now: TimeInterval) -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending = ""; lastPublication = now }
        return pending
    }
}
