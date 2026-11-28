import Foundation
import NoodleCore

/// The runner could not hold the model. `transient` refusals may pass when memory frees up, so they are retried;
/// the others (a prompt that never fits, an out-of-memory in the middle of a reply) are not.
struct ModelMemoryRefusal: LocalizedError {
    static let title = String(localized: "Your Mac is short on memory right now")
    static let detail = String(localized: "Close a few apps or pick a smaller model.")
    var transient = true
    var errorDescription: String? { Self.title }

    static func matches(status: Int, body: String) -> Bool { status == 400 && LocalModelMemoryRefusal.matches(body) }

    /// The runner's own message when generation runs out of GPU memory after the reply has started.
    static func matchesMidStream(_ message: String) -> Bool { message.contains("ran out of GPU memory") }

    /// Retries a refused request up to `attempts` times, `delay` apart. `onWait` brackets each wait; cancelling ends it.
    @MainActor static func retrying(attempts: Int = 3, delay: Duration = .seconds(10), onWait: @MainActor (Bool) -> Void,
                         _ operation: () async throws -> Void) async throws {
        for attempt in 0...attempts {
            do { return try await operation() } catch let refusal as ModelMemoryRefusal where refusal.transient && attempt < attempts {
                onWait(true)
                do { try await Task.sleep(for: delay) } catch { onWait(false); throw error }
                onWait(false)
            }
        }
    }
}
