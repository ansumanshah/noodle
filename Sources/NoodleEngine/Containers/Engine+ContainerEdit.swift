import Foundation
import NoodleCore

extension Engine {

    public func editContainer(_ ref: String, request: ContainerEditRequest) async throws -> ContainerEditResult {
        let id = try resolveContainerID(ref)
        var wasRunning = false
        let saved = try await withLock(id) { () async throws -> ContainerEditResult in
            wasRunning = containers[id].map { $0.status == .running || $0.status == .paused } ?? false
            return try await applyEdit(id, ref: ref, request: request)
        }
        guard request.restart && !request.dryRun else { return saved }
        // Same stop and start as `docker restart`, so nothing here can drift from it.
        do {
            if wasRunning { try await restartContainer(id) }
            else { try await withLock(id) { try await startLocked(id, manual: true) } }
        } catch {
            throw EngineError.internalError("Configuration saved, but container restart failed: \(error)")
        }
        return ContainerEditResult(message: "Configuration saved. Container restarted with the saved environment")
    }

    private func applyEdit(_ id: String, ref: String, request: ContainerEditRequest) async throws -> ContainerEditResult {
        do {
            guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
            guard [.created, .exited, .running, .paused].contains(c.status), !starting.contains(id) else {
                throw EngineError.conflict("Cannot edit container \(c.name) while it is \(c.status.rawValue)")
            }
            for key in request.unsetEnv {
                guard !key.isEmpty, !key.contains("="), !key.contains("\0") else { throw EngineError.invalid("invalid environment key: \(key)") }
            }
            for value in request.env {
                guard let separator = value.firstIndex(of: "="), separator != value.startIndex, !value.contains("\0") else {
                    throw EngineError.invalid("environment values must use KEY=VALUE")
                }
            }
            let additions = try request.publish.map { try Self.publication($0, removing: false) }
            let removals = try request.unpublish.map { try Self.publication($0, removing: true) }
            let changesPorts = !additions.isEmpty || !removals.isEmpty
            if changesPorts && (c.primaryNetwork == "host" || c.primaryNetwork == "none" || c.primaryNetwork.hasPrefix("container:")) {
                throw EngineError.conflict("Published ports require a container with its own bridge network")
            }
            let original = c
            let running = c.status == .running || c.status == .paused
            var bindings = running ? c.ports : (c.hostConfig.PortBindings ?? [:]).mapValues { $0 ?? [] }
            var kept = listeners[id] ?? []
            for removal in removals {
                guard let wanted = removal.binding else {
                    bindings[removal.key] = nil
                    kept.removeAll { "\($0.containerPort)/\($0.proto)" == removal.key }
                    continue
                }
                func matches(_ b: PortBinding) -> Bool {
                    let sameAddress = wanted.HostIp.isEmpty ? ["", "0.0.0.0", "::"].contains(b.HostIp) : wanted.HostIp == b.HostIp
                    return sameAddress && wanted.HostPort == b.HostPort
                }
                let previous = bindings[removal.key] ?? []
                bindings[removal.key] = previous.filter { !matches($0) }
                kept.removeAll { "\($0.containerPort)/\($0.proto)" == removal.key && matches(PortBinding(HostIp: $0.hostIP, HostPort: String($0.hostPort))) }
            }
            bindings = bindings.filter { !$0.value.isEmpty }
            c.config.Env = (c.config.Env ?? []).filter { value in
                !request.unsetEnv.contains(String(value.prefix(while: { $0 != "=" })))
            }
            c.config.Env = Self.mergeEnv(c.config.Env ?? [], request.env)
            let rt = runtime(for: c)
            let guestRef = rt.guest
            let gate = EditForwardingGate()
            let opener: PortListener.Opener = { op, ip, port in
                try gate.check()
                return try await guestRef.openStream(op, ["ip": .string(ip), "port": .int(Int64(port))])
            }
            // Stopped containers only reserve sockets for validation. No guest call or VM wake.
            let endpoint: EndpointRecord
            if running && changesPorts {
                guard let active = c.endpoints[c.primaryNetwork], !active.ip.isEmpty || active.ip6 != nil else {
                    throw EngineError.conflict("Container has no address for published ports")
                }
                endpoint = active
            } else { endpoint = EndpointRecord(networkID: "", endpointID: "", ip: "127.0.0.1") }
            var staged: [PortListener] = []
            do {
                for addition in additions {
                    guard let wanted = addition.binding else { continue }
                    let current = bindings[addition.key] ?? []
                    let already: Bool
                    if wanted.HostIp.isEmpty {
                        already = ["0.0.0.0", "::"].allSatisfy { address in
                            current.contains { $0.HostIp == address && $0.HostPort == wanted.HostPort }
                        }
                    } else { already = current.contains(wanted) }
                    if already { continue }
                    if !running && wanted.HostPort.isEmpty {
                        // Docker chooses the host port at start. Record the request; binding now would freeze a random port.
                        bindings[addition.key, default: []].append(wanted)
                        continue
                    }
                    let fields = addition.key.split(separator: "/")
                    let bound = try PortListener.publish(proto: String(fields[1]), hostIP: wanted.HostIp,
                        hostPort: Int(wanted.HostPort) ?? 0, endpoint: endpoint, containerPort: Int(fields[0])!, opener: opener) { staged.append($0) }
                    for listener in bound {
                        bindings[addition.key, default: []].append(PortBinding(HostIp: listener.hostIP, HostPort: String(listener.hostPort)))
                    }
                }
                if request.dryRun {
                    staged.forEach { $0.stop() }
                    return ContainerEditResult(message: "Dry run: configuration is valid. Nothing changed")
                }
                if changesPorts {
                    var stored = bindings.mapValues { Optional($0) }
                    // With -P an empty entry stops start from publishing that exposed port again.
                    if c.hostConfig.PublishAllPorts {
                        for key in removals.map(\.key) where stored[key] == nil && (c.config.ExposedPorts ?? [:]).keys.contains(key) { stored[key] = .some([]) }
                    }
                    c.hostConfig.PortBindings = stored
                    if running { c.ports = bindings }
                }
                containers[id] = c
                do { try persistState() }
                catch { containers[id] = original; throw error }
            } catch {
                staged.forEach { $0.stop() }
                throw error
            }
            if changesPorts && running {
                let retained = Set(kept.map(ObjectIdentifier.init))
                for listener in listeners[id] ?? [] where !retained.contains(ObjectIdentifier(listener)) { listener.stop() }
                listeners[id] = kept + staged
                gate.activate()
            } else { staged.forEach { $0.stop() } }
            refreshNames()
            emit("container", "update", id: id, attributes: containerAttributes(c))
            let envChanged = original.config.Env != c.config.Env
            return ContainerEditResult(message: running && envChanged
                ? "Configuration saved. Published ports apply now. Environment changes take effect at the next start; the running process environment is unchanged"
                : "Configuration saved")
        }
    }

}
