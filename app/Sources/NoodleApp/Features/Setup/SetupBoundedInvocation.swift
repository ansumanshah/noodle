import Darwin
import Foundation

/// Runs the CLI in its own process group so a timeout or cancel takes its Docker children down with it,
/// not just the immediate process. Foundation's Process cannot set a group, hence posix_spawn.
final class BoundedInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var timedOut = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let pid { killpg(pid, SIGKILL) }
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval?) -> CLI.Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-cli-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: url) else {
            try? FileManager.default.removeItem(at: url)
            return CLI.Result(code: 126, output: "Could not capture command output.")
        }
        defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
        lock.lock()
        if cancelled { lock.unlock(); return CLI.Result(code: 130, output: "Command cancelled.") }
        guard let child = spawnInProcessGroup(executable.path, arguments, output: output.fileDescriptor) else {
            lock.unlock()
            return CLI.Result(code: 126, output: "Could not launch \(executable.path).")
        }
        pid = child
        lock.unlock()
        let deadline = DispatchWorkItem { [self] in
            lock.lock()
            defer { lock.unlock() }
            if let pid {
                timedOut = true
                killpg(pid, SIGKILL)
            }
        }
        if let timeout { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline) }
        // Wait without reaping, forget the pid under the lock, then reap: a kill can never hit a reused pid.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        deadline.cancel()
        lock.lock()
        pid = nil
        let expired = timedOut
        let wasCancelled = cancelled
        lock.unlock()
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7f
        let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if expired {
            return CLI.Result(code: 124, output: "Command timed out. Refresh status before retrying; the cluster may still be changing.\n" + text)
        }
        return CLI.Result(code: wasCancelled ? 130 : code, output: text)
    }
}

/// Shared by the Setup runners: the child leads its own process group, starts with no blocked signals (worker threads
/// block SIGTERM and children inherit the mask) and default SIGTERM handling. `closing` is the read end of the capture pipe.
func spawnInProcessGroup(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                         input closing: Int32? = nil, output: Int32) -> pid_t? {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGTERM)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attributes, 0)
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output, 1)
    posix_spawn_file_actions_adddup2(&actions, output, 2)
    if let closing { posix_spawn_file_actions_addclose(&actions, closing) }
    if closing != nil { posix_spawn_file_actions_addclose(&actions, output) }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var child: pid_t = 0
    return posix_spawn(&child, executable, &actions, &attributes, &argv, &envp) == 0 ? child : nil
}
