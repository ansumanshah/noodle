import Foundation

extension FDChannel {
    /// The child takes over all reads. Holding the original open preserves the VM lease.
    func handoffReadDescriptor() throws -> FileHandle {
        try queue.sync {
            try lock.withLock {
                guard !closed, !paused, chunks.isEmpty, waiter == nil else { throw POSIXError(.EBUSY) }
                let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                guard copy >= 0 else { throw POSIXError(.EMFILE) }
                paused = true
                source?.suspend()
                return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
            }
        }
    }

    /// Half-close: the peer sees EOF, we can still read.
    func shutdownWrite() {
        writeQueue.async { [self] in
            lock.lock(); let c = closed; lock.unlock()
            if !c { _ = shutdown(fd, SHUT_WR) }
        }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        eof = true
        let w = waiter; waiter = nil
        let wasPaused = paused; paused = false
        lock.unlock()
        if wasPaused { source?.resume() }
        source?.cancel()
        closer.closeRequested()
        w?.resume(returning: nil)
    }
}
