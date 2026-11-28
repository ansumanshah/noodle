import Darwin
import Foundation

/// Serializes cancellation with launch, including cancellation before the detached task starts.
final class CapturedJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    var wasStopped: Bool { lock.withLock { stopped } }

    func start(_ process: Process) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            // The bounded command must release waitUntilExit even if it ignores SIGTERM.
            if let process, process.isRunning { Self.stopTree(process.processIdentifier) }
        }
    }
}


private extension CapturedJob {
    /// Stop descendants too: terminating only noodle could leave a scanner downloading in the background.
    static func stopTree(_ pid: pid_t) {
        guard pid > 1, kill(pid, SIGSTOP) == 0 else { return }
        // Freeze each parent before listing its children so it cannot launch another helper during cleanup.
        let required = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        let capacity = max(64, Int(max(0, required)) / MemoryLayout<pid_t>.stride + 64)
        var children = [pid_t](repeating: 0, count: capacity)
        let bytes = children.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), buffer.baseAddress, Int32(buffer.count))
        }
        if bytes > 0 {
            let count = min(children.count, Int(bytes) / MemoryLayout<pid_t>.stride)
            for child in children.prefix(count) where child > 1 && child != pid { stopTree(child) }
        }
        kill(pid, SIGKILL)
    }
}
