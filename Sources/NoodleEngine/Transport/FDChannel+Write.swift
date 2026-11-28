import Foundation

extension FDChannel {
    /// Send on the caller's thread when no write is queued, which skips two thread hops for a small control frame.
    /// The descriptor is non-blocking, so this never waits. False: nothing was sent, use `write`.
    func writeNow(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, queuedWrites == 0 else { return false }
        let n = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        if n == data.count { return true }
        guard n > 0 else { return false }
        // Rare: the socket took part of a frame. The rest goes through the queue, ahead of anything later.
        let rest = data.dropFirst(n)
        queuedWrites += 1
        writeQueue.async { [self] in
            var offset = 0
            let bytes = Data(rest)
            while offset < bytes.count {
                lock.lock(); let isClosed = closed; lock.unlock()
                if isClosed { break }
                let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + offset, $0.count - offset, 0) }
                if sent > 0 { offset += sent; continue }
                guard sent < 0, errno == EAGAIN || errno == EINTR else { break }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 200)
            }
            adjustQueuedWrites(-1)
        }
        return true
    }

    private func adjustQueuedWrites(_ delta: Int) {
        lock.lock(); queuedWrites += delta; lock.unlock()
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        adjustQueuedWrites(1)
        defer { adjustQueuedWrites(-1) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                var offset = 0
                while offset < data.count {
                    lock.lock(); let isClosed = closed; lock.unlock()
                    if isClosed { cont.resume(throwing: POSIXError(.EBADF)); return }
                    let n = data.withUnsafeBytes { raw in
                        send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                    }
                    if n > 0 { offset += n; continue }
                    if n < 0 && (errno == EAGAIN || errno == EINTR) {
                        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 200)
                        continue
                    }
                    cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE))
                    return
                }
                cont.resume()
            }
        }
    }
}
