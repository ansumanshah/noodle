import Foundation

/// Tracks successful socket I/O with a monotonic clock. Only accepted Finder
/// connections have a watchdog; an unused Finder server has no timer or task.
final class FinderServerConnection: @unchecked Sendable {
    private let channel: FDChannel
    let lock = NSLock()
    private var lastActivity = ContinuousClock.now
    private let writeFD: Int32
    private let writeQueue = DispatchQueue(label: "app.noodle.finder.write")
    private var closed = false

    init?(_ channel: FDChannel) {
        let descriptor = fcntl(channel.fd, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return nil }
        self.channel = channel
        writeFD = descriptor
    }

    func read() async throws -> Data? {
        let bytes = try await channel.read()
        if let bytes, !bytes.isEmpty { touch() }
        return bytes
    }

    func write(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                var offset = 0
                while offset < bytes.count {
                    guard !lock.withLock({ closed }) else {
                        done.resume(throwing: POSIXError(.EBADF)); return
                    }
                    let count = bytes.withUnsafeBytes { raw in
                        send(writeFD, raw.baseAddress! + offset, raw.count - offset, 0)
                    }
                    if count > 0 { touch(); offset += count; continue }
                    if count < 0, errno == EAGAIN || errno == EINTR {
                        var descriptor = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, 200)
                        continue
                    }
                    done.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE))
                    return
                }
                done.resume()
            }
        }
    }

    private func touch() { lock.withLock { lastActivity = ContinuousClock.now } }

    func close() {
        let first = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard first else { return }
        // Interrupt any blocked write before waiting for its queue to drain.
        _ = shutdown(writeFD, SHUT_RDWR)
        channel.close()
        writeQueue.async { [writeFD] in _ = Darwin.close(writeFD) }
    }

    deinit { close() }

    func closeWhenIdle() async {
        do {
            while !Task.isCancelled {
                let deadline = lock.withLock { lastActivity.advanced(by: .seconds(120)) }
                try await Task.sleep(until: deadline, clock: .continuous)
                let expired = lock.withLock { ContinuousClock.now >= lastActivity.advanced(by: .seconds(120)) }
                if expired { close(); return }
            }
        } catch { /* Cancellation ends the connection's watchdog. */ }
    }
}
