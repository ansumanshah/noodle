import Foundation
import NoodleCore

/// Local names, on demand: listeners exist only while a container or host dev route has a name.
extension Engine {
    public struct NamesStatus: Codable, Sendable {
        public var enabled: Bool
        public var port: Int
        public var httpsPort: Int?
        public var names: [LocalNames.Target]
        public var error: String?
        public var dns: LocalNameDNSStatus?
        /// Set when a standard port was taken: what holds it and which URL to use instead.
        public var notice: String?
        /// The local authority certificate to trust (`noodle names trust`) so browsers accept the HTTPS names.
        public var ca: String?
    }

    nonisolated static var namesEnabled: Bool { ProcessInfo.processInfo.environment["NOODLE_LOCAL_NAMES"] != "0" }
    /// Standard ports first (80, 443), then fallbacks 10080 and 10443. `NOODLE_NAMES_HTTP_PORT` and `NOODLE_NAMES_HTTPS_PORT`
    /// replace the standard ports (0 skips them); `NOODLE_HTTP_PORT` and `NOODLE_HTTPS_PORT` set the fallbacks.
    nonisolated static var namesConfig: NameRouter.Config {
        let env = ProcessInfo.processInfo.environment
        func port(_ key: String, _ fallback: Int) -> Int { env[key].flatMap { Int($0) } ?? fallback }
        return NameRouter.Config(httpPrimary: port("NOODLE_NAMES_HTTP_PORT", 80), httpsPrimary: port("NOODLE_NAMES_HTTPS_PORT", 443),
                                 httpFallback: port("NOODLE_HTTP_PORT", 10080), httpsFallback: port("NOODLE_HTTPS_PORT", 10443))
    }

    public func namesStatus() -> NamesStatus {
        refreshNames()
        let ca = LocalCA(paths: paths)
        let dns = nameRouter?.dns.status
        let errors = ([namesError].compactMap { $0 } + (dns?.errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } ?? []))
        return NamesStatus(enabled: Self.namesEnabled, port: nameRouter?.port ?? Self.namesConfig.httpPrimary, httpsPort: nameRouter?.httpsPort,
                           names: nameTable, error: errors.isEmpty ? nil : errors.joined(separator: " "), dns: dns, notice: namesNotice(), ca: nameRouter?.httpsPort == nil ? nil : ca.certificate.path)
    }

    public struct DevRegistration: Codable, Sendable {
        public let token: String
        public let host: String
        public let port: Int
        public let httpsPort: Int
        public let ca: String
    }

    /// Host-only targets are leased to the CLI, never persisted as containers or restored after its death.
    public func registerDev(host raw: String, port: Int, ownerPID: Int32) async throws -> DevRegistration {
        guard Self.namesEnabled else { throw EngineError.unavailable("Local names are off (NOODLE_LOCAL_NAMES=0).") }
        guard LocalNameDomain.isSupported(raw), let host = LocalNames.customHost(raw), host == raw, host.utf8.count <= 253,
              (1...65535).contains(port), NameRouter.ownerAlive(ownerPID) else {
            throw EngineError.badRequest("Expected a valid localhost or noodle.local name, port 1...65535 and live owner PID.")
        }
        refreshNames()
        guard !nameTable.contains(where: { $0.host == host }) else {
            throw EngineError.conflict("Local name \(host) is already in use. Choose another name.")
        }
        do {
            let router = try ensureNamesRouter()
            guard let https = router.httpsPort else { throw EngineError.unavailable("Local HTTPS is unavailable: \(router.httpsOff ?? "listener could not start")") }
            let token = try router.addDev(host: host, port: port, ownerPID: ownerPID)
            refreshNames()
            do {
                try await router.identities.prepare(host: host)
                if host.hasSuffix("." + LocalNameDomain.brandedSuffix) { try await router.dns.waitUntilRegistered(host) }
                // Actor reentrancy during DNS confirmation can remove the lease or its owner.
                guard router.devTargets().contains(where: { $0.containerID == "dev:" + token }) else {
                    throw EngineError.unavailable("The dev route owner has exited.")
                }
                let ca = try LocalCA(paths: paths).authority(for: host)
                return DevRegistration(token: token, host: host, port: router.port, httpsPort: https, ca: ca.certificate.path)
            } catch {
                router.removeDev(token)
                throw error
            }
        } catch {
            refreshNames()
            throw error
        }
    }

    public func unregisterDev(token: String) {
        nameRouter?.removeDev(token)
        refreshNames()
    }

    private func ensureNamesRouter() throws -> NameRouter {
        if let nameRouter { return nameRouter }
        let router = try NameRouter(config: Self.namesConfig, ca: LocalCA(paths: paths)) { [weak self] in
            Task { await self?.refreshNames() }
        }
        nameRouter = router
        namesError = nil
        if let notice = namesNotice() { FileHandle.standardError.write(Data("noodled: local names: \(notice)\n".utf8)) }
        return router
    }

    /// The message for a taken standard port: what holds it, and the URL that works instead.
    private func namesNotice() -> String? {
        guard let r = nameRouter else { return nil }
        let host = nameTable.first?.host ?? "<name>.localhost"
        var lines = ["http", "https"].compactMap { scheme in
            r.fallbacks[scheme].map { "\($0). Local names use \(scheme)://\(host):\(scheme == "http" ? r.port : r.httpsPort ?? 0)/ instead." }
        }
        if let off = r.httpsOff { lines.append("HTTPS is off: \(off)") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    func nameCandidates() -> [LocalNames.Candidate] {
        containers.values.compactMap { c in
            guard c.status == .running || c.status == .paused, c.primaryNetwork != "host", c.primaryNetwork != "none",
                  let ip = c.endpoints[c.primaryNetwork]?.ip, !ip.isEmpty else { return nil }
            func ports(_ keys: [String]) -> [Int] {
                keys.compactMap { k in PortSpec.parse(k).flatMap { $0.proto == "tcp" ? $0.port : nil } }
            }
            let published = ports(Array((c.hostConfig.PortBindings ?? [:]).keys) + Array(c.ports.keys))
            return LocalNames.Candidate(id: c.id, name: c.name, labels: c.config.Labels ?? [:], ip: ip, published: published,
                                        exposed: ports(Array((c.config.ExposedPorts ?? [:]).keys)), startedAt: c.startedAt ?? c.created)
        }
    }

    /// Recompute the table from the running set. Cheap, so it runs with every state change.
    func refreshNames() {
        guard Self.namesEnabled else { return }
        let dev = nameRouter?.devTargets() ?? []
        let reserved = Set(dev.map(\.host))
        // A dev lease keeps its name if a container starts later. Preserve the container at a disambiguated alias.
        let original = LocalNames.table(nameCandidates())
        var occupied = reserved.union(original.map(\.host).filter { !reserved.contains($0) })
        let containers = original.map { target in
            guard reserved.contains(target.host) else { return target }
            var renamed = target
            let parts = target.host.split(separator: ".", maxSplits: 1)
            let suffix = "-" + String(target.containerID.prefix(6))
            let label = String(parts[0].prefix(56)) + suffix
            var host = label + "." + parts[1]
            var counter = 1
            while occupied.contains(host) {
                let numbered = "-\(counter)"
                host = String(label.prefix(63 - numbered.count)) + numbered + "." + parts[1]
                counter += 1
            }
            occupied.insert(host)
            renamed.host = host
            return renamed
        }
        let taken = occupied.union(containers.map(\.host))
        let table = (containers + dev + hostTargets(excluding: taken)).sorted { $0.host < $1.host }
        guard table != nameTable || (table.isEmpty && nameRouter != nil) || (!table.isEmpty && nameRouter == nil) else { return }
        nameTable = table
        if table.isEmpty { nameRouter?.stop(); nameRouter = nil; namesError = nil; return }
        do { _ = try ensureNamesRouter() }
        catch { namesError = "\(error)"; return }
        var openers: [String: NameRouter.Opener] = [:]
        for t in containers where openers[t.containerID] == nil {
            let guest = runtime(t.containerID).guest
            openers[t.containerID] = { op, ip, port in try await guest.openStream(op, ["ip": .string(ip), "port": .int(Int64(port))]) }
        }
        nameRouter?.update(table, openers: openers)
    }
}

// MARK: - SSH agent forwarding (on demand)

extension Engine {
    /// Register the vsock listener and ask the guest to open its relay socket. Idempotent; first use only.
    func enableSSHAgent(in rt: GuestRuntime) async throws {
        let paths = self.paths
        await rt.vm.setGuestListener(port: SSHAgent.vsockPort) { fd in SSHAgent.serve(guestFD: fd, paths: paths) }
        _ = try await rt.guest.call("ssh_agent", [:])
    }

    /// The guest's Docker API socket relays to this daemon's own socket. Only containers that bound it get it.
    func enableDockerAPI(in rt: GuestRuntime) async throws {
        let paths = self.paths
        await rt.vm.setGuestListener(port: NoodleWire.dockerApiPort) { fd in SSHAgent.serveDockerAPI(guestFD: fd, paths: paths) }
        _ = try await rt.guest.call("docker_api", [:])
    }
}
