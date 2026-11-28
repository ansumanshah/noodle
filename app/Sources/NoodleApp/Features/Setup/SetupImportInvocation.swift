import Darwin
import Foundation

/// Import owns temporary helpers and mounts. Give its SIGTERM handler time to undo them.
/// All mutable state and signals share one lock; blocking waits run off the main actor.
final class SetupImportInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private let cleanupGrace: TimeInterval
    private var pid: pid_t?
    private var stoppedCode: Int32?
    private var forced = false
    private var escalation: DispatchSourceTimer?

    private init(cleanupGrace: TimeInterval) { self.cleanupGrace = cleanupGrace }

    static func run(_ source: String, flags: [String] = ["--all"], executable: URL? = CLI.locate(), timeout: TimeInterval = 3600,
                    cleanupGrace: TimeInterval = 60) async -> CLI.Result {
        let job = SetupImportInvocation(cleanupGrace: cleanupGrace)
        if Task.isCancelled { job.stop(code: 130) }
        return await withTaskCancellationHandler {
            await Task.detached {
                job.invoke(executable: executable, arguments: ["import", source] + flags, timeout: timeout)
            }.value
        } onCancel: { job.stop(code: 130) }
    }

    private func stop(code: Int32) {
        lock.withLock {
            guard stoppedCode == nil else { return }
            stoppedCode = code
            guard let pid else { return }
            // Only the importer gets TERM: its handler coordinates helper cleanup.
            kill(pid, SIGTERM)
            let escalation = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            escalation.schedule(deadline: .now() + cleanupGrace)
            escalation.setEventHandler { [self] in
                lock.withLock {
                    guard let pid = self.pid else { return }
                    var info = siginfo_t()
                    // An exited, unreaped child still owns its pid; do not mark it as forcibly killed.
                    var result: Int32
                    repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) }
                    while result != 0 && errno == EINTR
                    guard result == 0, info.si_pid == 0 else { return }
                    forced = killpg(pid, SIGKILL) == 0
                }
            }
            self.escalation = escalation
            escalation.resume()
        }
    }

    private func invoke(executable: URL?, arguments: [String], timeout: TimeInterval) -> CLI.Result {
        if lock.withLock({ stoppedCode != nil }) { return CLI.Result(code: 130, output: "Import cancelled.") }
        guard let executable else { return CLI.Result(code: 127, output: "The noodle command line tool was not found.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output")
        let output: FileHandle
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return CLI.Result(code: 126, output: "Could not capture import output.")
            }
            output = try FileHandle(forWritingTo: url)
        } catch { return CLI.Result(code: 126, output: error.localizedDescription) }
        defer { try? output.close() }
        lock.lock()
        if stoppedCode != nil { lock.unlock(); return CLI.Result(code: 130, output: "Import cancelled.") }
        guard let child = spawnInProcessGroup(executable.path, arguments, output: output.fileDescriptor) else {
            lock.unlock()
            return CLI.Result(code: 126, output: "Could not launch \(executable.path).")
        }
        pid = child
        lock.unlock()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [self] in stop(code: 124) }
        deadline.resume()
        // Observe exit without reaping. Clear the pid under the signal lock before releasing it to the OS.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        deadline.cancel()
        let outcome = lock.withLock {
            pid = nil
            escalation?.cancel()
            escalation = nil
            return (stoppedCode, forced)
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7f
        let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var notice = outcome.0 == 124 ? "Import timed out. Review the output before retrying.\n" : ""
        if outcome.1 { notice += "Import was forcibly stopped. Cleanup may be incomplete; review the output before retrying.\n" }
        return CLI.Result(code: outcome.0 ?? code, output: notice + text)
    }
}
