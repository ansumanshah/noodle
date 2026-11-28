import Foundation

/// The deadline must also cover a guest that never acknowledges the shutdown request.
/// A task-group race cannot do that: it waits for a non-cooperative child before returning.
enum VMShutdown {
    static func run(timeout: Duration, request: @Sendable () async -> Void,
                    wait: @Sendable () async -> Void, force: @escaping @Sendable () async -> Void) async {
        let deadline = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await force()
        }
        defer { deadline.cancel() }
        await request()
        await wait()
    }
}
