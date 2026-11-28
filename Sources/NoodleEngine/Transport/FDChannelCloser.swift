import Foundation

/// Closes the descriptor once the read source is cancelled and the owner has asked for it.
final class Closer: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var cancelled = false
    private var requested = false

    init(fd: Int32, queue: DispatchQueue) { self.fd = fd; self.queue = queue }

    func sourceCancelled() { update { cancelled = true } }
    func closeRequested() { update { requested = true } }

    private func update(_ change: () -> Void) {
        lock.lock()
        let before = cancelled && requested
        change()
        let ready = cancelled && requested && !before
        lock.unlock()
        if ready { queue.async { [fd] in _ = Darwin.close(fd) } }
    }
}
