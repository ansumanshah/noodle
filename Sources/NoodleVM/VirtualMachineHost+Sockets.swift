import Foundation
import Virtualization
import NoodleCore
import os

extension VirtualMachineHost {
    /// Listen for guest-initiated connections on `port`. Safe before `start()`; applied when the device exists.
    /// One handler per port; setting a port again replaces only that port's handler.
    public func setGuestListener(port: UInt32, handler: @escaping @Sendable (Int32) -> Void) {
        queue.async { [self] in
            listenerHandlers[port] = handler
            applyGuestListener(port: port)
        }
    }

    func applyGuestListeners() {
        for port in listenerHandlers.keys { applyGuestListener(port: port) }
    }

    private func applyGuestListener(port: UInt32) {
        guard let dev = socketDevice, let handler = listenerHandlers[port] else { return }
        let delegate = GuestListenerDelegate()
        delegate.handler = handler
        let l = VZVirtioSocketListener()
        l.delegate = delegate
        vsockListeners[port] = (l, delegate)
        dev.setSocketListener(l, forPort: port)
    }

    /// The agent connects here once it listens. The connection only carries that fact.
    func listenForAnnounce() {
        guard let dev = socketDevice else { return }
        announced = false
        readyDelegate.handler = { [weak self] fd in
            close(fd)
            guard let self else { return }
            self.queue.async { self.finishAnnounce() }
        }
        let l = VZVirtioSocketListener()
        l.delegate = readyDelegate
        readyListener = l
        dev.setSocketListener(l, forPort: NoodleWire.readyPort)
    }

    private func finishAnnounce() {
        announced = true
        let waiters = announceWaiters; announceWaiters = [:]
        for w in waiters.values { w.resume() }
    }

    /// Returns when the agent has announced itself, or after `timeout`. Nothing is armed once it has.
    public func waitForAnnounce(timeout: Duration) async {
        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if announced { cont.resume(); return }
                announceWaiters[id] = cont
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000))) { [self] in
                    announceWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    /// Connect to a guest vsock port. Returns an owned, duplicated file descriptor (caller closes it).
    public func connect(port: UInt32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            queue.async { [self] in
                guard let dev = socketDevice, vm?.state == .running else {
                    cont.resume(throwing: VMError.notRunning); return
                }
                dev.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        let fd = dup(conn.fileDescriptor)
                        conn.close()
                        if fd < 0 { cont.resume(throwing: VMError.connectFailed("dup: \(String(cString: strerror(errno)))")) }
                        else { cont.resume(returning: fd) }
                    case .failure(let e):
                        cont.resume(throwing: VMError.connectFailed("\(e)"))
                    }
                }
            }
        }
    }
}
