import Foundation
import NoodleCore

// Validation sockets must never reach the guest, including when a client connects
// during a dry run. Only a successful live transaction enables their opener.
final class EditForwardingGate: @unchecked Sendable {
    let lock = NSLock()
    private var enabled = false
    func activate() { lock.lock(); enabled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let active = enabled; lock.unlock()
        guard active else { throw EngineError.conflict("Port edit has not been applied") }
    }
}
