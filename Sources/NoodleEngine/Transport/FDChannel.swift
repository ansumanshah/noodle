import Foundation

/// Non-blocking file descriptor with a pull-based async read API, backpressure and ordered async writes.
/// Owns the descriptor: it stays open until `close()`, even after reads reach EOF, because the other direction may
/// still be in use. The number must not be reused while a write or half-close is queued, or that call would hit
/// whatever connection got the number next. So the real close runs on the write queue, after the source is cancelled.
final class FDChannel: @unchecked Sendable {
    let fd: Int32
    let queue: DispatchQueue
    let writeQueue: DispatchQueue
    var source: DispatchSourceRead?
    let lock = NSLock()
    var chunks: [Data] = []
    private var buffered = 0
    var eof = false
    private var failure: Error?
    var waiter: CheckedContinuation<Data?, Error>?
    var paused = false
    var closed = false
    let closer: Closer
    /// Writes handed to `writeQueue` and not finished. Guarded by `lock`.
    var queuedWrites = 0
    /// Read scratch, touched only from `queue`. Allocated on the first readable event, uninitialised.
    private var scratch: UnsafeMutableRawPointer?
    private static let scratchSize = 64 * 1024
    private static let highWater = 1 << 20
    private static let lowWater = 256 << 10

    init(fd: Int32, label: String = "app.noodle.fd") {
        self.fd = fd
        queue = DispatchQueue(label: label + ".r")
        writeQueue = DispatchQueue(label: label + ".w")
        closer = Closer(fd: fd, queue: writeQueue)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.onReadable() }
        let closer = self.closer
        s.setCancelHandler { closer.sourceCancelled() }
        source = s
        s.resume()
    }

    private func onReadable() {
        let buf = scratch ?? malloc(Self.scratchSize)!
        scratch = buf
        let n = Darwin.read(fd, buf, Self.scratchSize)
        if n > 0 {
            deliver(Data(bytes: buf, count: n))
        } else if n == 0 {
            finish(nil)
        } else if errno != EAGAIN && errno != EINTR {
            finish(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func deliver(_ d: Data) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: d)
            return
        }
        chunks.append(d); buffered += d.count
        if buffered > Self.highWater, !paused, !closed { paused = true; source?.suspend() }
        lock.unlock()
    }

    private func finish(_ error: Error?) {
        lock.lock()
        eof = true
        if failure == nil { failure = error }
        let w = waiter; waiter = nil
        let wasPaused = paused
        paused = false
        lock.unlock()
        if wasPaused { source?.resume() }
        source?.cancel()
        if let w {
            if let error { w.resume(throwing: error) } else { w.resume(returning: nil) }
        }
    }

    /// Next chunk, or nil at end of stream.
    func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if !chunks.isEmpty {
                    let d = chunks.removeFirst(); buffered -= d.count
                    let resume = paused && buffered < Self.lowWater
                    if resume { paused = false }
                    lock.unlock()
                    if resume { source?.resume() }
                    cont.resume(returning: d)
                } else if eof {
                    let f = failure; failure = nil
                    lock.unlock()
                    if let f { cont.resume(throwing: f) } else { cont.resume(returning: nil) }
                } else {
                    waiter = cont
                    lock.unlock()
                }
            }
            try Task.checkCancellation()
            return data
        } onCancel: {
            // This channel owns the descriptor. Closing it also releases an idle read,
            // allowing the stream owner to run its cleanup when its client disconnects.
            self.close()
        }
    }

    deinit {
        close()
        // The cancel handler holds `queue` until pending events drain; free after that.
        let p = scratch
        if p != nil { queue.async { free(p) } }
    }
}
