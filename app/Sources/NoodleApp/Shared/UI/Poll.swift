import Foundation

/// Runs `work` every `interval` until the surrounding task is cancelled. `runFirst: false` waits one interval first.
@MainActor func poll(every interval: Duration, tolerance: Duration? = nil, runFirst: Bool = true,
                     _ work: @MainActor () async -> Void) async {
    if runFirst, !Task.isCancelled { await work() }
    while !Task.isCancelled {
        do { try await Task.sleep(for: interval, tolerance: tolerance) } catch { return }
        await work()
    }
}
