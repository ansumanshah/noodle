import Darwin
import Foundation

/// One pull owns a process group. Output reads are nonblocking and serialized off the main actor.
final class SetupPullInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "dev.getnoodle.setup-pull-output")
    private let onLine: @Sendable (String) -> Void
    private var pid: pid_t?
    private var stoppedCode: Int32?
    private var escalation: DispatchSourceTimer?
    // Accessed only on outputQueue.
    private var pending = Data()
    private var all = Data()
    private var reachedEOF = false

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func stop(code: Int32 = 130) {
        lock.withLock {
            guard stoppedCode == nil else { return }
            stoppedCode = code
            guard let pid else { return }
            killpg(pid, SIGTERM)
            let escalation = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            escalation.schedule(deadline: .now() + 0.25)
            escalation.setEventHandler { [self] in
                lock.withLock { if let pid = self.pid { killpg(pid, SIGKILL) } }
            }
            self.escalation = escalation
            escalation.resume()
        }
    }

    /// Bounded work per event, and at most 1 MiB at completion, even with a writer that never closes stdout.
    private func drain(_ fd: Int32, limit: Int) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var left = limit
        while left > 0 {
            let count = read(fd, &buffer, min(buffer.count, left))
            if count < 0 && errno == EINTR { continue }
            if count == 0 { reachedEOF = true }
            guard count > 0 else { return }
            left -= count
            let chunk = Data(buffer.prefix(count))
            // Keep a bounded transcript and partial line, including output without line endings.
            all.append(chunk)
            if all.count > 1_048_576 { all.removeFirst(all.count - 1_048_576) }
            pending.append(chunk)
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if !line.isEmpty { onLine(line) }
            }
            if pending.count > 65_536 { pending.removeFirst(pending.count - 65_536) }
        }
    }

    func run(executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> CLI.Result {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return CLI.Result(code: 126, output: "Could not capture command output.") }
        let input = descriptors[0], output = descriptors[1]
        // A read event and final drain must never wait for an inherited writer.
        guard fcntl(input, F_SETFL, O_NONBLOCK) == 0 else {
            close(input); close(output)
            return CLI.Result(code: 126, output: "Could not capture command output.")
        }
        _ = fcntl(input, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output, F_SETFD, FD_CLOEXEC)
        lock.lock()
        if let code = stoppedCode {
            lock.unlock(); close(input); close(output)
            return CLI.Result(code: code, output: "Command cancelled.")
        }
        guard let child = spawnInProcessGroup(executable, arguments, environment: environment, input: input, output: output) else {
            lock.unlock(); close(input); close(output)
            return CLI.Result(code: 126, output: "Could not launch \(executable).")
        }
        pid = child
        lock.unlock()
        close(output)
        let reader = DispatchSource.makeReadSource(fileDescriptor: input, queue: outputQueue)
        reader.setEventHandler { [self] in
            drain(input, limit: 65_536)
            if reachedEOF { reader.suspend() }
        }
        reader.setCancelHandler { close(input) }
        reader.resume()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [self] in stop(code: 124) }
        deadline.resume()
        // Keep the pid reserved until all signals have finished, then reap it exactly once.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        deadline.cancel()
        let stopped: Int32? = lock.withLock {
            // A wrapper can exit before its children. Stop them before forgetting the group.
            killpg(child, SIGKILL)
            pid = nil
            escalation?.cancel()
            escalation = nil
            return stoppedCode
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        let text = outputQueue.sync {
            let suspended = reachedEOF
            drain(input, limit: 1_048_576)
            reader.cancel()
            if suspended { reader.resume() }
            if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
            return String(decoding: all, as: UTF8.self)
        }
        let signal = status & 0x7f
        let code = stopped ?? (signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        return CLI.Result(code: code, output: code == 124 ? "Command timed out.\n" + text : text)
    }
}
