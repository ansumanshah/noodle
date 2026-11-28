import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension Engine {
    // MARK: guest readiness

    /// Boot the VM if needed and make sure the guest knows our networks/volumes (it forgets everything at power off).
    func ensureGuest(_ rt: GuestRuntime? = nil) async throws {
        let rt = rt ?? main
        let name = rt.role == .main ? "Noodle" : "Noodle workload"
        do { try await rt.vm.ensureRunning() } catch { throw EngineError.unavailable("the \(name) VM could not start: \(error)") }
        let boot = await rt.vm.bootCount
        if rt.epoch == boot { return }
        if let t = rt.setup, rt.setupEpoch == boot { try await t.value; return }
        let t = Task { try await self.prepareGuest(rt, boot: boot) }
        rt.setup = t; rt.setupEpoch = boot
        try await t.value
    }

    private func prepareGuest(_ rt: GuestRuntime, boot: Int) async throws {
        rt.forgetBoot()
        rt.epochStart = Date()
        // The guest has no trustworthy wall clock at boot; log timestamps and `--since/--until` compare against the host's.
        let now = Date().timeIntervalSince1970
        let sec = Int64(now)
        _ = try? await rt.guest.call(GuestOp.setTime, ["sec": .int(sec), "nsec": .int(Int64((now - Double(sec)) * 1e9))])
        await enableHostLoopback(in: rt)
        if rt === main { await modelBridgeObserver?(true) }
        let r = pendingLists(rt)
        if !r.layers.isEmpty, (try? await rt.guest.call(GuestOp.layerRemove, ["digests": .strings(r.layers)])) != nil {
            updatePending(rt) { $0.layers.removeAll { r.layers.contains($0) } }
            scheduleSave()
        }
        for id in r.containers {
            if (try? await rt.guest.call(GuestOp.remove, ["container": .string(id)])) != nil {
                updatePending(rt) { $0.containers.removeAll { $0 == id } }
                scheduleSave()
            }
        }
        for name in r.volumes {
            try? await withLock("volume:\(name)") { try await removePendingGuestVolume(name, rt) }
        }
        rt.epoch = boot
    }

    func vmDidStop(_ rt: GuestRuntime) async {
        if rt === main { await modelBridgeObserver?(false) }
        let mine = containers.values.filter { runtime(for: $0) === rt }
        for c in mine { stopHealth(c.id) }
        if rt === main { hostEvents.removeAll(); hostLoopbackRelay?.closeAll() }
        await rt.guest.disconnect()
        rt.epoch = -1
        rt.forgetBoot()
        // A VM that went away under running containers (crash, forced stop): they are gone.
        let now = Date()
        // `mine` predates the awaits above: re-read each record so a removed or already-exited container is skipped.
        for stale in mine {
            guard var c = containers[stale.id], c.isRunningLike, runtime(for: c) === rt else { continue }
            c.status = .exited; c.exitCode = 137; c.pid = 0; c.finishedAt = now
            for k in c.endpoints.keys { c.endpoints[k]?.ip = ""; c.endpoints[k]?.ip6 = nil }
            containers[c.id] = c
            releaseRuntime(c.id)
            emit("container", "die", id: c.id, attributes: containerAttributes(c, extra: ["exitCode": "137"]))
            resumeWaiters(c.id, WaitResult(StatusCode: 137, Error: nil))
            if !shuttingDown { let id = c.id; Task { await self.afterExit(id) } }   // the restart policy answers a dead VM like any exit
        }
        let ids = Set(mine.map(\.id))
        for (id, e) in execs where e.running && ids.contains(e.containerID) { execs[id]?.stream?.close(); execFinished(id, code: 137) }
        scheduleSave(); refreshBusy()
    }

    // MARK: guest events

    func guestEvent(_ ev: GuestEvent, from rt: GuestRuntime) {
        func owns(_ id: String) -> Bool { Self.eventAllowed(from: rt.role, containerRole: containers[id].map { runtime(for: $0).role }) }
        switch ev {
        case .exit(let id, let code):
            guard owns(id) else { return }
            if starting.contains(id) { pendingExits[id] = code } else { containerExited(id, code: code) }
        case .oom(let id):
            guard owns(id), var c = containers[id] else { return }
            c.oomKilled = true; containers[id] = c
            emit("container", "oom", id: id, attributes: containerAttributes(c))
        case .execExit(let eid, let code):
            guard let e = execs[eid], owns(e.containerID) else { return }
            execFinished(eid, code: Int(code))
        case .dnsQuery, .unknown: break
        }
    }
}
