import Foundation

/// A scoped download child. Cancellation forwards to its group, then reaps it before cleanup.
/// Blocking: use only on a CLI thread or worker, never a NIO event loop.
public final class ToolDownloadProcess: @unchecked Sendable {
    public struct Result: Sendable {
        public let code: Int32
        public let cancelledSignal: Int32?
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var received: Int32?
    public init() {}

    public func cancel(_ number: Int32) {
        let child = lock.withLock {
            if received == nil { received = number }
            if pid > 0 { _ = kill(-pid, number) }
            return pid
        }
        if child > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.withLock { if pid == child { _ = kill(-child, SIGKILL) } }
            }
        }
    }

    public func run(executable: String, arguments: [String]) throws -> Result {
        var attributes: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else { throw POSIXError(POSIXErrorCode(rawValue: initialized) ?? .EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for number in [SIGINT, SIGTERM, SIGHUP] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var variables = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv { free(value) }; for value in variables { free(value) } }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, executable, nil, &attributes, &argv, &variables)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        let pending = lock.withLock { pid = child; return received }
        if let pending { cancel(pending) }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        return lock.withLock {
            pid = 0
            let signal = status & 0x7f
            return Result(code: signal == 0 ? (status >> 8) & 0xff : 128 + signal, cancelledSignal: received)
        }
    }
}
