import Darwin

extension ModelRunner {
    func reapOrphan(_ session: Session?, termSeconds: Double) {
        guard let session, let pid = session.process?.pid, session.ownsProcessGroup == true,
              Self.groupRuns(session.executable, pgid: pid), kill(-pid, SIGTERM) == 0 else { return }
        let gone: () -> Bool = { kill(-pid, 0) != 0 }
        if !waitFor(gone, seconds: termSeconds) { _ = kill(-pid, SIGKILL) }
        _ = waitFor(gone, seconds: 5)
    }

    /// A recorded pgid can belong to another program after a reboot; only signal a group that still runs our runtime binary.
    static func groupRuns(_ executable: String, pgid: pid_t) -> Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).contains { pid in
            pid > 0 && getpgid(pid) == pgid && arguments(of: pid).contains(executable)
        }
    }

    /// argv of a process (KERN_PROCARGS2: argc, exec path, padding, then argv strings); covers interpreted runtimes too.
    static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst().prefix(argc))  // drop the exec path
    }
}
