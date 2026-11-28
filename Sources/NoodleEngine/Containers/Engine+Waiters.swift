import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension Engine {
    // MARK: waiting

    func addWaiter(_ id: String, timeout: Duration?) async -> WaitResult? {
        let token = UUID()
        let deadline = timeout.map { timeout in
            Task { [weak self] in
                do { try await Task.sleep(for: timeout, tolerance: .milliseconds(200)) }
                catch { return }
                await self?.timeoutWaiter(id, token)
            }
        }
        defer { deadline?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<WaitResult?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                } else {
                    exitWaiters[id, default: [:]][token] = cont
                }
            }
        } onCancel: {
            Task { await self.timeoutWaiter(id, token) }
        }
    }

    private func timeoutWaiter(_ id: String, _ token: UUID) {
        let continuation = exitWaiters[id]?.removeValue(forKey: token)
        if exitWaiters[id]?.isEmpty == true { exitWaiters[id] = nil }
        continuation?.resume(returning: nil)
    }

    func cancelAllWaiters() {
        let waiting = exitWaiters
        exitWaiters = [:]
        for continuations in waiting.values {
            for continuation in continuations.values { continuation.resume(returning: nil) }
        }
    }

    func resumeWaiters(_ id: String, _ result: WaitResult) {
        guard let ws = exitWaiters.removeValue(forKey: id) else { return }
        for (_, c) in ws { c.resume(returning: result) }
    }
}
