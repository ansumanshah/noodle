import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    public func createExec(_ ref: String, config: ExecConfig) throws -> String {
        let id = try resolveContainerID(ref)
        guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        guard c.status == .running else {
            throw EngineError.conflict(c.status == .paused ? "Container \(c.name) is paused, unpause the container before exec" : "Container \(c.id) is not running")
        }
        guard !config.Cmd.isEmpty else { throw EngineError.badRequest("No exec command specified") }
        if config.Privileged, !Self.usesWorkload(c) {
            throw EngineError.invalid("exec --privileged needs the container to run in the privileged VM. Container \(c.name) runs in the main VM, and a running process cannot be moved. Recreate it with --privileged, then exec --privileged works")
        }
        let eid = IDs.random64()
        execs[eid] = ExecRecord(id: eid, containerID: id, config: config)
        c.execIDs.append(eid)
        containers[id] = c
        emit("container", "exec_create: " + config.Cmd.joined(separator: " "), id: id, attributes: containerAttributes(c, extra: ["execID": eid]))
        return eid
    }

    /// Start an exec. Returns the multiplexed stream, or nil when `detach` is true.
    public func startExec(_ execID: String, detach: Bool = false, tty: Bool? = nil) async throws -> GuestStream? {
        guard var e = execs[execID] else { throw EngineError.notFound("No such exec instance: \(execID)") }
        guard !e.running else { throw EngineError.conflict("Exec instance already running") }
        guard let c = containers[e.containerID], c.status == .running else { throw EngineError.conflict("Container \(e.containerID) is not running") }
        let cfg = e.config
        let env = Self.mergeEnv(c.config.Env ?? [], cfg.Env ?? [])
        let stream: GuestStream
        do {
            stream = try await runtime(for: c).guest.openStream(StreamOp.exec, [
                "exec": .string(execID), "container": .string(c.id), "argv": .strings(cfg.Cmd), "env": .strings(env),
                "cwd": .string(cfg.WorkingDir.isEmpty ? c.config.WorkingDir : cfg.WorkingDir),
                "user": .string(cfg.User.isEmpty ? c.config.User : cfg.User),
                "tty": .bool(tty ?? cfg.Tty), "stdin": .bool(cfg.AttachStdin && !detach), "privileged": .bool(cfg.Privileged)])
        } catch let failure as GuestError {
            // Docker's exit codes for a command that never ran: 127 when it is missing, 126 otherwise.
            execFinished(execID, code: failure.errno == 2 ? 127 : 126)
            throw failure
        }
        e.running = true; e.stream = stream; e.exitCode = nil
        execs[execID] = e
        emit("container", "exec_start: " + cfg.Cmd.joined(separator: " "), id: c.id, attributes: containerAttributes(c, extra: ["execID": execID]))
        let me = self
        stream.frameObserver = { f in
            if let code = f.exitCode { Task { await me.execFinished(execID, code: Int(code)) } }
        }
        if detach {
            Task {
                while let f = try? await stream.nextFrame() { if f.kind == .exit { break } }
                stream.close()
            }
            return nil
        }
        return stream
    }

    static let execGrace: TimeInterval = 300

    func execFinished(_ id: String, code: Int) {
        guard var e = execs[id], e.finished == nil else { return }
        // The record outlives the exec (inspect); the stream, its fd and decoder buffers must not. The consumer holds its own reference.
        e.running = false; e.exitCode = code; e.stream = nil; e.finished = Date()
        execs[id] = e
        // Docker drops finished execs from ExecIDs; keep the 50 newest finished records per container for inspect,
        // plus any finished within the grace window: a client inspects the exit code after draining the output.
        containers[e.containerID]?.execIDs.removeAll { $0 == id }
        let done = execs.values.filter { $0.containerID == e.containerID && $0.finished != nil }.sorted { $0.finished! > $1.finished! }
        for old in done.dropFirst(50) where Date().timeIntervalSince(old.finished!) > Self.execGrace { execs[old.id] = nil }
        if let c = containers[e.containerID] {
            emit("container", "exec_die", id: c.id, attributes: containerAttributes(c, extra: ["execID": id, "exitCode": String(code)]))
        }
    }

    public func inspectExec(_ id: String) throws -> ExecInspect {
        guard let e = execs[id] else { throw EngineError.notFound("No such exec instance: \(id)") }
        var i = ExecInspect()
        i.ID = id; i.ContainerID = e.containerID; i.Running = e.running; i.ExitCode = e.running ? nil : e.exitCode
        i.OpenStdin = e.config.AttachStdin; i.OpenStdout = e.config.AttachStdout; i.OpenStderr = e.config.AttachStderr
        i.ProcessConfig.entrypoint = e.config.Cmd.first ?? ""; i.ProcessConfig.arguments = Array(e.config.Cmd.dropFirst())
        i.ProcessConfig.tty = e.config.Tty; i.ProcessConfig.user = e.config.User; i.ProcessConfig.privileged = e.config.Privileged
        i.Pid = e.pid
        return i
    }

    public func resizeExec(_ id: String, rows: Int, cols: Int) async throws {
        guard let e = execs[id] else { throw EngineError.notFound("No such exec instance: \(id)") }
        try await e.stream?.resize(rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
    }
}
