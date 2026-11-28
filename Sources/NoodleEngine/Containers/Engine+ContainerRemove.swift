import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: wait / remove / rename / update

    public func waitContainer(_ ref: String, condition: String = "not-running") async throws -> WaitResult {
        let id = try resolveContainerID(ref)
        let c = containers[id]!
        if condition != "next-exit" && condition != "removed" && !c.isRunningLike {
            return WaitResult(StatusCode: c.exitCode, Error: nil)
        }
        guard var result = await addWaiter(id, timeout: nil) else { throw CancellationError() }
        // "removed" resolves at destroy, not at die.
        while condition == "removed", containers[id] != nil {
            guard let next = await addWaiter(id, timeout: nil) else { throw CancellationError() }
            result = next
        }
        return result
    }

    public func removeContainer(_ ref: String, force: Bool = false, removeVolumes: Bool = false) async throws {
        let id = try resolveContainerID(ref)
        try await withLock(id) {
            guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
            if c.isRunningLike {
                guard force else {
                    throw EngineError.conflict("cannot remove container \"\(c.name)\": container is running: stop the container before removing or force remove")
                }
                restartTasks[id]?.cancel(); restartTasks[id] = nil
                c.stoppedByUser = true; containers[id] = c
                if c.status != .restarting {
                    _ = try? await runtime(id).guest.call(GuestOp.kill, ["container": .string(id), "signal": .int(9)])
                    _ = await waitForStop(id, seconds: 15)
                    if containers[id]?.isRunningLike == true { containerExited(id, code: 137) }
                } else {
                    containers[id]?.status = .exited
                }
                c = containers[id]!
            }
            stopHealth(id)
            releaseRuntime(id)
            let rt = runtime(for: c)
            if await rt.vm.isRunning { _ = try? await rt.guest.call(GuestOp.remove, ["container": .string(id)], boot: false) }
            else if !pendingLists(rt).containers.contains(id) { updatePending(rt) { $0.containers.append(id) } }
            rt.containers.remove(id); rt.createdSpecs[id] = nil
            hostEvents.remove(containerID: id); await rt.vm.removeHostShares(containerID: id)
            for (eid, e) in execs where e.containerID == id { e.stream?.close(); execs[eid] = nil }
            containers[id] = nil; attachesBeforeStart[id] = nil
            if removeVolumes {
                for m in c.mounts where m.Type == "volume" {
                    guard let name = m.Name, volumes[name]?.anonymous == true else { continue }
                    try? await removeVolume(name)
                }
            }
            resumeWaiters(id, WaitResult(StatusCode: c.exitCode, Error: nil))
            scheduleSave(); refreshBusy()
            emit("container", "destroy", id: id, attributes: containerAttributes(c))
        }
    }
}
