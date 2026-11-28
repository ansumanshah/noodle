import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: exit handling

    /// Free everything tied to a running container: port listeners, IP leases, runtime ports.
    func releaseRuntime(_ id: String) {
        for l in listeners.removeValue(forKey: id) ?? [] { l.stop() }
        for n in networks.keys { releaseAddresses(network: n, container: id) }
        if var c = containers[id] {
            c.ports = [:]
            for k in c.endpoints.keys { c.endpoints[k]?.ip = ""; c.endpoints[k]?.ip6 = nil; c.endpoints[k]?.mac = "" }
            containers[id] = c
        }
    }

    func containerExited(_ id: String, code: Int32) {
        guard var c = containers[id], c.isRunningLike else { return }
        stopHealth(id)
        c.status = .exited; c.exitCode = Int(code); c.pid = 0; c.finishedAt = Date()
        containers[id] = c
        let nets = Set(c.endpoints.values.map(\.networkID))
        releaseRuntime(id)
        c = containers[id]!
        runtime(id).containers.insert(id)
        emit("container", "die", id: id, attributes: containerAttributes(c, extra: ["exitCode": String(code)]))
        resumeWaiters(id, WaitResult(StatusCode: Int(code), Error: nil))
        for (eid, e) in execs where e.containerID == id && e.running { execFinished(eid, code: Int(code)) }
        scheduleSave(); refreshBusy()
        Task { [nets] in
            try? await self.withLock(id) {
                if await self.containers[id]?.status == .exited {
                    self.hostEvents.remove(containerID: id); await self.runtime(id).vm.removeHostShares(containerID: id)
                }
            }
            for n in nets { if let net = await self.networks[n] { await self.syncDNS(net) } }
            await self.afterExit(id)
        }
    }

    func afterExit(_ id: String) async {
        guard !shuttingDown, let c = containers[id], c.status == .exited else { return }
        if c.hostConfig.AutoRemove {
            try? await removeContainer(id, force: true)
            return
        }
        guard !c.stoppedByUser else { return }
        let p = c.hostConfig.RestartPolicy
        let wants: Bool
        switch p.Name {
        case "always", "unless-stopped": wants = true
        case "on-failure": wants = c.exitCode != 0 && (p.MaximumRetryCount == 0 || c.restartCount < p.MaximumRetryCount)
        default: wants = false
        }
        guard wants else { return }
        var cc = c
        let ran = c.startedAt.flatMap { s in c.finishedAt.map { $0.timeIntervalSince(s) } } ?? 0
        let (step, delay) = Self.restartBackoff(step: c.restartStep ?? 0, ranFor: ran)
        cc.status = .restarting; cc.restartCount += 1; cc.restartStep = step + 1
        containers[id] = cc
        refreshBusy(); scheduleSave()
        restartTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)), tolerance: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.withLock(id) {
                    guard await self.containers[id]?.status == .restarting else { return }
                    try await self.startLocked(id, manual: false)
                }
                await self.emitRestarted(id)
            } catch {
                await self.restartFailed(id)
            }
            await self.clearRestartTask(id)
        }
    }

    /// Docker's restart backoff: 100 ms doubling to 60 s, back to 100 ms once a run lasted longer than 10 s.
    static func restartBackoff(step: Int, ranFor: TimeInterval) -> (step: Int, delay: Double) {
        let s = ranFor > 10 ? 0 : step
        return (s, min(0.1 * pow(2, Double(min(s, 10))), 60))
    }

    /// A `docker rm -f` can land between the restart and this event, so the container may already be gone.
    func emitRestarted(_ id: String) {
        guard let c = containers[id] else { return }
        emit("container", "restart", id: id, attributes: containerAttributes(c))
    }

    func restartFailed(_ id: String) {
        guard var c = containers[id], c.status == .restarting || c.status == .created else { return }
        c.status = .exited; containers[id] = c; scheduleSave(); refreshBusy()
    }
}
