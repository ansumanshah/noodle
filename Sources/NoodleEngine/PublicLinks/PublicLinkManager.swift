import Foundation
import NoodleCore

final class PublicLinkManager: @unchecked Sendable {
    struct Entry {
        var status: PublicLinkStatus
        var listener: PortListener?
        var process: Process?
        var control: Pipe?
        var output: Pipe?
        var buffer = Data()
        var directory: URL?
        var helperPID: Int32?
        var helperStart: UInt64?
    }
    private let paths: NoodlePaths
    let lock = NSLock()
    var entries: [String: Entry] = [:]
    private var history: URL { paths.root.appendingPathComponent("public-links.json") }

    init(paths: NoodlePaths) {
        self.paths = paths
        // History records are never executable instructions. Startup never reads this file on its own.
        if let data = try? Data(contentsOf: history), let old = try? JSONDecoder().decode([PublicLinkStatus].self, from: data) {
            for var status in old {
                if status.state == "running" || status.state == "starting" {
                    status.state = "stopped"; status.detail = "daemon stopped; link was not restored"
                }
                status.pid = nil
                entries[status.id] = Entry(status: status)
            }
        }
    }

    func all() -> [PublicLinkStatus] { lock.lock(); defer { lock.unlock() }; return entries.values.map(\.status).sorted { $0.id < $1.id } }
    func status(_ id: String) -> PublicLinkStatus? { lock.lock(); defer { lock.unlock() }; return entries[id]?.status }
    func saveLocked() throws {
        let data = try JSONEncoder().encode(entries.values.map(\.status))
        try data.write(to: history, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
    }

    func prepare(_ target: PublicLinkTarget, listener: PortListener, liveContainers: Set<String>) throws -> String {
        lock.lock(); defer { lock.unlock() }
        // History would grow forever: a stopped link whose container is gone is dropped on the next save.
        // A stopped link keeps its entry until `exited` has reaped its helper and listener.
        entries = entries.filter { $0.value.status.state != "stopped" || $0.value.process != nil || $0.value.listener != nil || liveContainers.contains($0.value.status.containerID) }
        let id = UUID().uuidString.lowercased()
        let status = PublicLinkStatus(id: id, containerID: target.containerID, containerName: target.containerName,
                                      containerIP: target.containerIP, containerPort: target.containerPort,
                                      target: "http://127.0.0.1:\(listener.hostPort)", state: "starting")
        entries[id] = Entry(status: status, listener: listener)
        do { try saveLocked() } catch { entries[id] = nil; listener.stop(); throw error }
        return id
    }

    func launch(_ id: String, binary: (path: String, sha256: String)) throws {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id], entry.status.state == "starting" else { throw EngineError.invalid("link was stopped before launch") }
        let directory = paths.tmpDir.appendingPathComponent("public-link-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        entries[id]?.directory = directory
        let process = Process(), control = Pipe(), output = Pipe()
        // A small CLI supervisor watches stdin EOF. The kernel closes the writer even if noodled crashes.
        guard let cli = Engine.linkSupervisorURL() else { try? FileManager.default.removeItem(at: directory); throw EngineError.unavailable("noodle must be installed beside noodled to supervise public links") }
        process.executableURL = cli
        process.arguments = ["link", "_supervise", binary.path, entry.status.target, directory.path, binary.sha256]
        var environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "NOODLE_LINK_SUPERVISOR": "1"]
        let hostEnv = ProcessInfo.processInfo.environment
        if hostEnv["NOODLE_CLOUDFLARED"] != nil || hostEnv["NOODLE_CLOUDFLARED_ARCHIVE"] != nil {
            for key in ["NOODLE_LINK_TEST_ARGS", "NOODLE_LINK_TEST_PID"] { environment[key] = hostEnv[key] }
        }
        process.environment = environment
        process.standardInput = control; process.standardOutput = output; process.standardError = output
        // The daemon's ends must never leak into other children. The helper's ends are dup2'd onto 0/1/2 by the spawn.
        _ = fcntl(control.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        entry.process = process; entry.control = control; entry.output = output; entry.directory = directory
        entries[id] = entry
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(id, data: data)
        }
        process.terminationHandler = { [weak self] process in self?.exited(id, code: process.terminationStatus) }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? control.fileHandleForWriting.close()
            entries[id]?.process = nil; entries[id]?.control = nil; entries[id]?.output = nil
            entries[id]?.directory = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        // Only the supervisor owns the read side; a daemon crash must produce EOF.
        try? control.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        entries[id]?.status.pid = process.processIdentifier
        try saveLocked()
    }
}
