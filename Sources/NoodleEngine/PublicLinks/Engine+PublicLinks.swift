import Foundation
import NoodleCore

// Public HTTPS links are separate helpers. This file does not implement Docker's legacy --link.

extension Engine {

    public func startPublicLink(_ ref: String, port: Int?, confirmed: Bool, allowPrivileged: Bool) async throws -> PublicLinkStatus {
        guard confirmed else { throw EngineError.invalid("publishing requires --yes or interactive confirmation") }
        let target = try publicLinkTarget(ref, port: port, allowPrivileged: allowPrivileged)
        let startedAt = containers[target.containerID]?.startedAt
        let binary = try await Task.detached { try PublicLinkManager.binary(paths: self.paths) }.value
        // Downloading can suspend this actor. Recheck both identity and lifetime before opening anything.
        let checked = try publicLinkTarget(target.containerID, port: target.containerPort, allowPrivileged: allowPrivileged)
        guard checked.containerIP == target.containerIP, containers[target.containerID]?.startedAt == startedAt else {
            throw EngineError.invalid("container changed while preparing the link; run the command again")
        }
        guard let manager = PublicLinkRegistry.shared.manager(self, create: true) else {
            throw EngineError.unavailable("daemon is shutting down; public link was not started")
        }
        let guest = runtime(target.containerID).guest
        let listener = try PortListener(proto: "tcp", hostIP: "127.0.0.1", hostPort: 0,
                                        containerIP: target.containerIP, containerPort: target.containerPort,
                                        noodleOwned: true) { [weak self] op, ip, port in
            guard let self, await self.publicLinkStillValid(target, startedAt: startedAt) else {
                throw EngineError.invalid("container lifetime ended")
            }
            let stream = try await guest.openStream(op, ["ip": .string(ip), "port": .int(Int64(port))])
            guard await self.publicLinkStillValid(target, startedAt: startedAt) else {
                stream.close()
                throw EngineError.invalid("container lifetime ended while connecting")
            }
            return stream
        }
        // The manager owns the listener, not Engine.listeners: container teardown must not free the port while the helper may
        // still be alive. Per-connection checks and the lifecycle events stop traffic instead.
        let id = try manager.prepare(target, listener: listener, liveContainers: Set(containers.keys))
        do {
            try await Task.detached { try manager.launch(id, binary: binary) }.value
            for _ in 0..<150 {
                try Task.checkCancellation()
                guard let status = manager.status(id) else { throw EngineError.internalError("link disappeared") }
                if status.state == "running" { return status }
                if status.state != "starting" { throw EngineError.unavailable(status.detail ?? "tunnel stopped") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw EngineError.unavailable("cloudflared did not provide a public URL within 15 seconds")
        } catch {
            manager.stop(id, reason: "link startup failed")
            throw error
        }
    }

    private func publicLinkStillValid(_ target: PublicLinkTarget, startedAt: Date?) -> Bool {
        guard let c = containers[target.containerID] else { return false }
        return c.status == .running && c.startedAt == startedAt && c.endpoints[c.primaryNetwork]?.ip == target.containerIP
            && namespaceSiblings(of: target.containerID).isEmpty
    }

    /// Other live containers (running, paused or restarting) whose network mode joins this container's namespace.
    func namespaceSiblings(of id: String) -> [ContainerRecord] {
        guard let c = containers[id] else { return [] }
        return containers.values.filter { other in
            guard other.id != id, [.running, .paused, .restarting].contains(other.status),
                  other.hostConfig.NetworkMode.hasPrefix("container:") else { return false }
            let target = String(other.hostConfig.NetworkMode.dropFirst("container:".count))
            return target == id || target == c.name || (target.count >= 4 && id.hasPrefix(target))
        }
    }

    public func publicLinks() -> [PublicLinkStatus] {
        PublicLinkRegistry.shared.manager(self, create: true)?.all() ?? []
    }

    public func stopPublicLink(_ id: String) async throws {
        guard let manager = PublicLinkRegistry.shared.manager(self, create: true) else { return }
        if id == "--all" {
            let statuses = manager.all()
            manager.stopAll(reason: "stopped by user")
            await Task.detached { manager.waitForExit(statuses.map(\.id)) }.value
            return
        }
        guard manager.status(id) != nil else { throw EngineError.notFound("No such public link: \(id)") }
        manager.stop(id, reason: "stopped by user")
        await Task.detached { manager.waitForExit([id]) }.value
    }

    // Called from Engine.shutdown and Engine.emit before publishing lifecycle events.
    func shutdownPublicLinks() async {
        guard let manager = PublicLinkRegistry.shared.close(self) else { return }
        let ids = manager.all().map(\.id)
        manager.stopAll(reason: "daemon stopped; links are never restored")
        await Task.detached { manager.waitForExit(ids) }.value
    }
    func revokePublicLinks(type: String, action: String, id: String, attributes: [String: String]) {
        let containerID: String
        if type == "network", action == "disconnect", let affected = attributes["container"] { containerID = affected }
        else if type == "container", ["die", "stop", "destroy", "kill", "pause"].contains(action) { containerID = id }
        else if type == "container", ["start", "unpause", "restart"].contains(action) {
            // A sibling that joins a published container's namespace later would be exposed by the link.
            guard let joined = containers[id], joined.hostConfig.NetworkMode.hasPrefix("container:") else { return }
            let target = String(joined.hostConfig.NetworkMode.dropFirst("container:".count))
            for owner in containers.values where owner.id != id && (target == owner.id || target == owner.name || (target.count >= 4 && owner.id.hasPrefix(target))) {
                PublicLinkRegistry.shared.manager(self, create: false)?.stopContainer(owner.id)
            }
            return
        }
        else { return }
        PublicLinkRegistry.shared.manager(self, create: false)?.stopContainer(containerID)
    }
}
