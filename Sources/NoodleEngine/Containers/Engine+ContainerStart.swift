import Foundation
import NoodleCore
import NoodleImages

// MARK: - Lifecycle

extension Engine {
    static let signals: [String: Int] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "BUS": 7, "FPE": 8, "KILL": 9, "USR1": 10, "SEGV": 11,
        "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15, "STKFLT": 16, "CHLD": 17, "CONT": 18, "STOP": 19, "TSTP": 20,
        "TTIN": 21, "TTOU": 22, "URG": 23, "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27, "WINCH": 28, "IO": 29, "PWR": 30, "SYS": 31,
    ]

    /// `SIGTERM`, `term`, `15` -> 15.
    static func signalNumber(_ s: String?) throws -> Int {
        guard let s, !s.isEmpty else { return 15 }
        if let n = Int(s), (1...64).contains(n) { return n }
        var name = s.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        guard let n = signals[name] else { throw EngineError.invalid("Invalid signal: \(s)") }
        return n
    }

    public func startContainer(_ ref: String) async throws {
        let id = try resolveContainerID(ref)
        try await withLock(id) { try await startLocked(id, manual: true) }
    }

    func startLocked(_ id: String, manual: Bool) async throws {
        guard let current = containers[id] else { throw EngineError.notFound("No such container: \(id)") }
        if current.status == .running || current.status == .paused { throw EngineError.notModified("container already started") }
        if manual {
            restartTasks[id]?.cancel(); restartTasks[id] = nil
            var c = current; c.stoppedByUser = false; c.restartCount = 0; c.restartStep = nil; containers[id] = c
        }
        starting.insert(id); pendingExits[id] = nil
        defer {
            starting.remove(id)
            if let code = pendingExits.removeValue(forKey: id) { containerExited(id, code: code) }
        }
        do {
            try await withActivity { try await performStart(id) }
            attachesBeforeStart[id] = nil
        } catch {
            // `docker run` attached first and waits on that stream, so it has to end for the error to show.
            attachesBeforeStart.removeValue(forKey: id)?.forEach { $0.close() }
            if containers[id]?.hostConfig.AutoRemove == true {
                Task { try? await self.removeContainer(id, force: true) }
            }
            hostEvents.remove(containerID: id); await runtime(id).vm.removeHostShares(containerID: id)
            releaseRuntime(id)
            if var c = containers[id] {
                c.status = c.finishedAt == nil ? .created : .exited
                c.error = "\(error)"
                containers[id] = c
            }
            scheduleSave(); refreshBusy()
            if let e = error as? EngineError { throw e }
            if let g = error as? GuestError { throw EngineError.internalError("\(g.message)") }
            throw error
        }
    }

    /// `docker compose restart` restarts a service and the containers that share its network namespace at the same
    /// time. The joiner's start must not land in the owner's stop-to-start gap, so wait while the owner is mid-restart.
    /// An owner that is simply stopped is not waited for: the guest reports it as not running.
    func awaitNetworkOwner(_ c: ContainerRecord) async {
        guard c.primaryNetwork.hasPrefix("container:"),
              let owner = try? resolveContainerID(String(c.primaryNetwork.dropFirst(10))) else { return }
        let deadline = Date().addingTimeInterval(60)
        while (restartingIDs.contains(owner) || starting.contains(owner)) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func performStart(_ id: String) async throws {
        var c = containers[id]!
        await awaitNetworkOwner(c)
        c = containers[id] ?? c
        // A removed network stays on a stopped container; Docker refuses to start it rather than drop the network.
        if let gone = c.endpoints.first(where: { networks[$0.value.networkID] == nil })?.key {
            throw EngineError.notFound("network \(gone) not found")
        }
        let image: LocalImage
        if let i = await imageStore.get(id: c.imageID) { image = i } else { throw EngineError.notFound("No such image: \(c.image)") }
        for mount in c.guestMounts where mount.kind == "bind" { try validateBindSource(mount.source) }
        if Self.usesWorkload(c) { try validateWorkloadBinds(c) }
        let rt = runtime(for: c)
        try await ensureGuest(rt)
        let usedLayerCache = try await ensureLayers(image, in: rt)
        for m in c.guestMounts where m.kind == "volume" { try await ensureGuestVolume(m.source, in: rt) }
        if c.guestMounts.contains(where: { $0.kind == "agent" }) { try await enableSSHAgent(in: rt) }
        if c.guestMounts.contains(where: { $0.kind == "docker" }) { try await enableDockerAPI(in: rt) }

        // networking
        var primaryEndpoint: EndpointRecord?
        var primaryNet: NetworkRecord?
        var secondary: [(NetworkRecord, EndpointRecord)] = []
        for (name, ep) in c.endpoints.sorted(by: { $0.key < $1.key }) {
            guard let n = networks[ep.networkID] else { continue }
            try await ensureGuestNet(n, in: rt)
            let e = try allocateEndpoint(containerID: id, on: n)
            if name == c.primaryNetwork { primaryEndpoint = e; primaryNet = n } else { secondary.append((n, e)) }
        }
        c = containers[id]!

        // published ports: bind before starting so conflicts fail fast
        try bindPorts(&c, endpoint: primaryEndpoint, in: rt)
        containers[id] = c

        var spec = try buildSpec(c, primary: primaryEndpoint, net: primaryNet)
        let hostMounts = spec.mounts
        // No bind mounts: nothing to share, so leave the VM's share table alone.
        if spec.mounts.contains(where: { $0.kind == "bind" }) {
            spec.mounts = try await rt.vm.setHostShares(containerID: id, mounts: spec.mounts)
            // shortcut: Mac edits are relayed as inotify events to the main VM only; workload binds see changes on read.
            if rt === main { hostEvents.add(containerID: id, mounts: hostMounts, mapped: spec.mounts) }
        }
        spec.layers = image.layers.reversed().map(\.digest)
        let (op, args) = try GuestRequests.create(container: id, spec: spec)
        // One round trip when the guest does not hold the container yet and nothing has to run in between.
        let started = try await createInGuest(image, usedCache: usedLayerCache, op, args, thenStart: secondary.isEmpty, in: rt)
        rt.containers.insert(id)
        for (n, e) in secondary {
            try await rt.guest.call(GuestOp.netConnect, netConnectArgs(n, container: id, e))
        }
        let r: [String: JSONValue]
        if let started { r = started } else { r = try await rt.guest.call(GuestOp.start, ["container": .string(id)]) }
        c = containers[id]!
        c.status = .running; c.pid = Int(r["pid"]?.int ?? 0); c.startedAt = Date(); c.error = ""
        c.oomKilled = false; c.exitCode = 0
        containers[id] = c
        // The state change and its event stay together. A container that joins this one's network namespace may
        // start during the DNS sync below, and its start event must not come first.
        emit("container", "start", id: id, attributes: containerAttributes(c))
        startHealth(id)
        for n in Set(c.endpoints.values.map(\.networkID)) { if let net = networks[n] { await syncDNS(net) } }
        scheduleSave(); refreshBusy()
    }

}
