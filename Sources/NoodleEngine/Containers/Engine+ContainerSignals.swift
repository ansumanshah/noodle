import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: stop / kill / restart

    public func stopContainer(_ ref: String, signal: String? = nil, timeout: Int? = nil) async throws {
        let id = try resolveContainerID(ref)
        // A start in flight (restart policy included) holds the lock and would overwrite our state; let it finish, then stop what it started.
        if starting.contains(id) { try await withLock(id) {} }
        guard let c0 = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        guard c0.isRunningLike else { throw EngineError.notModified("container already stopped") }
        var c = c0
        c.stoppedByUser = true
        containers[id] = c
        restartTasks[id]?.cancel(); restartTasks[id] = nil
        if c.status == .restarting {
            c.status = .exited; containers[id] = c; scheduleSave(); refreshBusy()
            return
        }
        try await withActivity {
            if c.status == .paused { _ = try? await runtime(id).guest.call(GuestOp.unpause, ["container": .string(id)]) }
            let sig = try Self.signalNumber(signal ?? c.config.StopSignal)
            let limit = timeout ?? c.config.StopTimeout ?? 10
            try await runtime(id).guest.call(GuestOp.kill, ["container": .string(id), "signal": .int(Int64(sig))])
            if await !waitForStop(id, seconds: limit < 0 ? nil : limit) {
                _ = try? await runtime(id).guest.call(GuestOp.kill, ["container": .string(id), "signal": .int(9)])
                _ = await waitForStop(id, seconds: 15)
            }
        }
        if let cc = containers[id] { emit("container", "stop", id: id, attributes: containerAttributes(cc)) }
    }

    /// True once the container is no longer running.
    func waitForStop(_ id: String, seconds: Int?) async -> Bool {
        guard let c = containers[id], c.isRunningLike else { return true }
        let r = await addWaiter(id, timeout: seconds.map { .seconds($0) })
        return r != nil
    }

    public func killContainer(_ ref: String, signal: String? = nil) async throws {
        let id = try resolveContainerID(ref)
        guard let c = containers[id], c.isRunningLike else { throw EngineError.conflict("Container \(ref) is not running") }
        let sig = try Self.signalNumber(signal ?? "KILL")
        try await runtime(id).guest.call(GuestOp.kill, ["container": .string(id), "signal": .int(Int64(sig))])
        emit("container", "kill", id: id, attributes: containerAttributes(c, extra: ["signal": String(sig)]))
    }

    public func restartContainer(_ ref: String, signal: String? = nil, timeout: Int? = nil) async throws {
        let id = try resolveContainerID(ref)
        restartingIDs.insert(id)
        defer { restartingIDs.remove(id) }
        if containers[id]?.isRunningLike == true { try await stopContainer(id, signal: signal, timeout: timeout) }
        try await withLock(id) { try await startLocked(id, manual: true) }
        if let c = containers[id] { emit("container", "restart", id: id, attributes: containerAttributes(c)) }
    }

    public func pauseContainer(_ ref: String) async throws {
        let id = try resolveContainerID(ref)
        guard let first = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        guard first.status == .running else {
            throw EngineError.conflict(first.status == .paused ? "Container \(ref) is already paused" : "Container \(ref) is not running")
        }
        try await runtime(id).guest.call(GuestOp.pause, ["container": .string(id)])
        // The actor is reentrant: a kill during the guest call may have ended the container already.
        guard var c = containers[id], c.status == .running else { return }
        c.status = .paused; containers[id] = c; scheduleSave()
        stopHealth(id)
        emit("container", "pause", id: id, attributes: containerAttributes(c))
    }

    public func unpauseContainer(_ ref: String) async throws {
        let id = try resolveContainerID(ref)
        guard let first = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        guard first.status == .paused else { throw EngineError.conflict("Container \(ref) is not paused") }
        try await runtime(id).guest.call(GuestOp.unpause, ["container": .string(id)])
        guard var c = containers[id], c.status == .paused else { return }
        c.status = .running; containers[id] = c; scheduleSave()
        startHealth(id, resume: true)
        emit("container", "unpause", id: id, attributes: containerAttributes(c))
    }

}
