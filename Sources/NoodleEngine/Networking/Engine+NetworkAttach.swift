import Foundation
import NoodleCore

extension Engine {
    func ensureGuestNet(_ n: NetworkRecord, in rt: GuestRuntime? = nil) async throws {
        let rt = rt ?? main
        guard n.driver == "bridge", !rt.nets.contains(n.id) else { return }
        var args: [String: JSONValue] = ["network": .string(n.name), "bridge": .string(n.bridgeName),
                                         "subnet": .string(n.subnet), "gateway": .string(n.gateway), "internal": .bool(n.isInternal)]
        if let sub6 = n.subnet6, let gw6 = n.gateway6 { args["subnet6"] = .string(sub6); args["gateway6"] = .string(gw6) }
        try await rt.guest.call(GuestOp.netCreate, args)
        rt.nets.insert(n.id)
    }

    /// Push the DNS records for every running container on the network (names, aliases, short id).
    /// Each VM only gets the containers it runs: names resolve inside one VM.
    func syncDNS(_ n: NetworkRecord) async {
        // The default bridge has no name resolution, the same as Docker's: only links reach names there.
        guard n.driver == "bridge", !n.builtin else { return }
        for rt in runtimes where rt.nets.contains(n.id) {
            var records: [JSONValue] = []
            for c in containersOn(n) where runtime(for: c) === rt {
                guard let e = c.endpoints[n.name], !e.ip.isEmpty || e.ip6 != nil else { continue }
                var names = Set([c.name, c.shortID] + e.aliases)
                if !c.config.Hostname.isEmpty { names.insert(c.config.Hostname) }
                for name in names.sorted() {
                    var record: [String: JSONValue] = ["name": .string(name)]
                    if !e.ip.isEmpty { record["ip"] = .string(e.ip) }
                    if let ip6 = e.ip6 { record["ip6"] = .string(ip6) }
                    records.append(.object(record))
                }
            }
            _ = try? await rt.guest.call(GuestOp.dnsSet, ["network": .string(n.name), "records": .array(records)])
        }
    }

    static func requestedMAC(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.range(of: "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$", options: .regularExpression) != nil,
              let first = UInt8(value.prefix(2), radix: 16), first & 1 == 0 else {
            throw EngineError.invalid("invalid MAC address \(value)")
        }
        return value.lowercased()
    }

    // MARK: connect / disconnect

    public func connectNetwork(_ netRef: String, container ref: String, endpoint: EndpointSettings? = nil) async throws {
        let nid = try networkID(netRef)
        let id = try resolveContainerID(ref)
        try await withLock(id) {
            guard let n = networks[nid] else { throw EngineError.notFound("network \(netRef) not found") }
            guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
            if c.endpoints[n.name] != nil { throw EngineError.conflict("container \(c.shortID) is already connected to network \(n.name)") }
            if n.driver != "bridge" { throw EngineError.conflict("container cannot be connected to network of type \(n.driver)") }
            var e = EndpointRecord(networkID: n.id, endpointID: IDs.random64(), aliases: endpoint?.Aliases ?? [])
            e.staticIP = try requestedIP(endpoint, on: n)
            e.staticIP6 = try requestedIP6(endpoint, on: n)
            e.requestedMAC = try Self.requestedMAC(endpoint?.MacAddress)
            e.links = endpoint?.Links ?? []
            c.endpoints[n.name] = e
            containers[id] = c
            if c.isRunningLike {
                do {
                    try await ensureGuestNet(n, in: runtime(for: c))
                    try await attach(containerID: id, to: n, primary: false)
                } catch {
                    releaseAddresses(network: n.id, container: id)
                    containers[id]?.endpoints[n.name] = nil
                    throw error
                }
                await syncDNS(n)
            }
            scheduleSave()
            emit("network", "connect", id: n.id, attributes: ["container": id, "name": n.name, "type": n.driver])
        }
    }

    public func disconnectNetwork(_ netRef: String, container ref: String) async throws {
        let nid = try networkID(netRef)
        let id = try resolveContainerID(ref)
        try await withLock(id) {
            guard let n = networks[nid] else { throw EngineError.notFound("network \(netRef) not found") }
            guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
            guard c.endpoints[n.name] != nil else { throw EngineError.conflict("container \(c.shortID) is not connected to network \(n.name)") }
            if c.isRunningLike, await runtime(for: c).vm.isRunning {
                _ = try? await runtime(for: c).guest.call(GuestOp.netDisconnect, ["network": .string(n.name), "container": .string(id)], boot: false)
            }
            releaseAddresses(network: n.id, container: id)
            c.endpoints[n.name] = nil
            containers[id] = c
            if c.isRunningLike { await syncDNS(n) }
            scheduleSave()
            emit("network", "disconnect", id: n.id, attributes: ["container": id, "name": n.name, "type": n.driver])
        }
    }

    /// Reserve an address on `n` for the container (host side only).
    @discardableResult
    func allocateEndpoint(containerID id: String, on n: NetworkRecord) throws -> EndpointRecord {
        guard var c = containers[id], var e = c.endpoints[n.name] else { throw EngineError.internalError("no endpoint") }
        guard n.driver == "bridge", !n.subnet.isEmpty || n.subnet6 != nil else {
            throw EngineError.internalError("network \(n.name) has no address pool")
        }
        var macBits: UInt32 = 0
        if var pool = ipam(n) {
            let ip = try pool.allocate(for: id, preferred: e.staticIP.flatMap { IPv4Net.parse($0) })
            ipams[n.id] = pool
            e.ip = IPv4Net.string(ip)
            macBits = ip
        }
        e.ip6 = nil
        if var pool6 = ipam6(n), n.subnet.isEmpty || !Self.disablesIPv6(c) {
            let ip6 = try pool6.allocate(for: id, preferred: e.staticIP6.flatMap { IPv6Addr($0) })
            ipams6[n.id] = pool6
            e.ip6 = ip6.string
            if n.subnet.isEmpty { macBits = UInt32(truncatingIfNeeded: ip6.lo) }
        }
        e.mac = e.requestedMAC ?? MAC.forIP(macBits)
        c.endpoints[n.name] = e
        containers[id] = c
        return e
    }

    /// Allocate and tell the guest about a secondary network of an already created container (`net_connect`).
    @discardableResult
    func attach(containerID id: String, to n: NetworkRecord, primary: Bool) async throws -> EndpointRecord {
        let e = try allocateEndpoint(containerID: id, on: n)
        if !primary {
            var args = netConnectArgs(n, container: id, e)
            if let c = containers[id], let resolver = guestResolver(for: c) { args["resolver"] = resolver.json }
            try await runtime(id).guest.call(GuestOp.netConnect, args)
        }
        return e
    }
}
