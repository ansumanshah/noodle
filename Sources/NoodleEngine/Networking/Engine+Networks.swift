import Foundation
import NoodleCore

// MARK: - Networks

extension Engine {
    static let defaultSubnet = "172.18.0.0/16"

    func ensureBuiltinNetworks() {
        let now = Date()
        if !networks.values.contains(where: { $0.name == "bridge" }) {
            let id = IDs.random64()
            networks[id] = NetworkRecord(id: id, name: "bridge", driver: "bridge", created: now, subnet: Self.defaultSubnet,
                                         gateway: "172.18.0.1", builtin: true, bridgeName: "noodle0")
        }
        for n in ["host", "none"] where !networks.values.contains(where: { $0.name == n }) {
            let id = IDs.random64()
            networks[id] = NetworkRecord(id: id, name: n, driver: n == "none" ? "null" : "host", created: now, subnet: "",
                                         gateway: "", builtin: true, bridgeName: "")
        }
    }

    func networkID(_ ref: String) throws -> String {
        if networks[ref] != nil { return ref }
        if let n = networks.values.first(where: { $0.name == ref }) { return n.id }
        let m = networks.values.filter { $0.id.hasPrefix(ref) }
        if m.count == 1 { return m[0].id }
        if m.count > 1 { throw EngineError.conflict("network \(ref) is ambiguous (\(m.count) matches found based on ID prefix)") }
        throw EngineError.notFound("network \(ref) not found")
    }

    func ipam(_ net: NetworkRecord) -> IPAM? {
        if let p = ipams[net.id] { return p }
        guard let cidr = IPv4Net(cidr: net.subnet) else { return nil }
        let p = IPAM(net: cidr, gateway: IPv4Net.parse(net.gateway), range: net.ipRange.flatMap { IPv4Net(cidr: $0, prefixes: 1...32) },
                     reserved: Set((net.auxAddresses ?? [:]).values.compactMap(IPv4Net.parse)), label: "\(net.name) (\(net.id))")
        ipams[net.id] = p
        return p
    }

    func allocateSubnet() throws -> IPv4Net {
        var candidates: [IPv4Net] = []
        for second in 19...31 { candidates.append(IPv4Net(base: 172 << 24 | UInt32(second) << 16, prefix: 16)) }
        for third in stride(from: 0, to: 256, by: 16) where third != 64 { // 192.168.64.0/24 is the VM's own uplink
            candidates.append(IPv4Net(base: 192 << 24 | 168 << 16 | UInt32(third) << 8, prefix: 20))
        }
        let used = networks.values.compactMap { IPv4Net(cidr: $0.subnet) }
        guard let pick = candidates.first(where: { c in !used.contains { $0.overlaps(c) } }) else {
            throw EngineError.internalError("could not find an available, non-overlapping IPv4 address pool among the defaults to assign to the network")
        }
        return pick
    }

    public func createNetwork(_ req: NetworkCreateRequest) async throws -> (id: String, warning: String) {
        guard !req.Name.isEmpty else { throw EngineError.badRequest("network name is required") }
        if networks.values.contains(where: { $0.name == req.Name }) {
            throw EngineError.conflict("network with name \(req.Name) already exists")
        }
        guard ["bridge", "", "default"].contains(req.Driver) else {
            throw EngineError.invalid("plugin \"\(req.Driver)\" not found (only the bridge driver is supported)")
        }
        guard req.EnableIPv4 != false || req.EnableIPv6 else { throw EngineError.invalid("IPv4 or IPv6 must be enabled") }
        let pool = try resolvePool(req)
        let pool6 = try resolvePool6(req)
        let id = IDs.random64()
        var rec = NetworkRecord(id: id, name: req.Name, driver: "bridge", created: Date(), subnet: pool?.net.cidr ?? "",
                                gateway: pool.map { IPv4Net.string($0.gateway) } ?? "", ipRange: pool?.range, isInternal: req.Internal, attachable: req.Attachable,
                                enableIPv6: req.EnableIPv6, labels: req.Labels ?? [:], options: req.Options ?? [:],
                                builtin: false, bridgeName: "br-" + id.prefix(12), auxAddresses: pool?.aux, userSubnet: pool?.userSubnet)
        if let pool6 {
            rec.subnet6 = pool6.net.cidr; rec.gateway6 = pool6.gateway.string; rec.ipRange6 = pool6.range
            rec.auxAddresses6 = pool6.aux; rec.userSubnet6 = pool6.userSubnet
        }
        networks[id] = rec
        scheduleSave()
        emit("network", "create", id: id, attributes: ["name": req.Name, "type": "bridge"])
        return (id, "")
    }

    public func listNetworks(filters: Filters = Filters()) -> [NetworkResource] {
        networks.values
            .filter { n in
                if !filters.regexMatches("name", n.name) { return false }
                if !filters["id"].isEmpty, !filters["id"].contains(where: { n.id.hasPrefix($0) }) { return false }
                if !filters["driver"].isEmpty, !filters["driver"].contains(n.driver) { return false }
                if !filters["type"].isEmpty, !filters["type"].contains(n.builtin ? "builtin" : "custom") { return false }
                if let dangling = filters.bool("dangling"), dangling != containersOn(n).isEmpty { return false }
                return filters.matchLabels(n.labels)
            }
            .sorted { $0.created < $1.created }
            .map { resource($0) }
    }

    func containersOn(_ n: NetworkRecord) -> [ContainerRecord] {
        containers.values.filter { $0.endpoints[n.name] != nil && $0.isRunningLike }
    }

    func resource(_ n: NetworkRecord) -> NetworkResource {
        var r = NetworkResource()
        r.Name = n.name; r.Id = n.id; r.Created = ISO8601.string(n.created); r.Driver = n.driver
        r.EnableIPv4 = n.builtin || !n.subnet.isEmpty
        r.EnableIPv6 = n.enableIPv6; r.Internal = n.isInternal; r.Attachable = n.attachable
        r.Options = n.options; r.Labels = n.labels
        var pools: [IPAMPool] = []
        if !n.subnet.isEmpty { pools.append(IPAMPool(Subnet: n.subnet, Gateway: n.gateway, IPRange: n.ipRange, AuxiliaryAddresses: n.auxAddresses)) }
        if let sub6 = n.subnet6 { pools.append(IPAMPool(Subnet: sub6, Gateway: n.gateway6, IPRange: n.ipRange6, AuxiliaryAddresses: n.auxAddresses6)) }
        if !pools.isEmpty { r.IPAM.Config = pools }
        if n.name == "bridge" { r.Options["com.docker.network.bridge.name"] = "docker0" }
        for c in containersOn(n) {
            guard let e = c.endpoints[n.name], !e.ip.isEmpty || e.ip6 != nil else { continue }
            var nc = NetworkContainer()
            nc.Name = c.name; nc.EndpointID = e.endpointID; nc.MacAddress = e.mac
            if !e.ip.isEmpty { nc.IPv4Address = "\(e.ip)/\(IPv4Net(cidr: n.subnet)?.prefix ?? 16)" }
            if let ip6 = e.ip6 { nc.IPv6Address = "\(ip6)/\(n.subnet6.flatMap { IPv6Net(cidr: $0) }?.prefix ?? 64)" }
            r.Containers[c.id] = nc
        }
        return r
    }

    public func inspectNetwork(_ ref: String) throws -> NetworkResource {
        resource(networks[try networkID(ref)]!)
    }

    public func removeNetwork(_ ref: String) async throws {
        let id = try networkID(ref)
        let n = networks[id]!
        if n.builtin { throw EngineError.conflict("\(n.name) is a pre-defined network and cannot be removed") }
        if !containersOn(n).isEmpty { throw EngineError.conflict("error while removing network: network \(n.name) has active endpoints") }
        // Stopped containers keep their endpoint, so their next start fails with "network ... not found" as in Docker.
        networks[id] = nil; ipams[id] = nil; ipams6[id] = nil
        for rt in runtimes where rt.nets.remove(id) != nil {
            if await rt.vm.isRunning { _ = try? await rt.guest.call(GuestOp.netRemove, ["network": .string(n.name)], boot: false) }
        }
        scheduleSave()
        emit("network", "destroy", id: id, attributes: ["name": n.name, "type": n.driver])
    }

    public func pruneNetworks(filters: Filters = Filters()) async -> NetworkPruneResponse {
        var out = NetworkPruneResponse()
        for n in networks.values where !n.builtin && containers.values.allSatisfy({ $0.endpoints[n.name] == nil }) && filters.matchLabels(n.labels) {
            if (try? await removeNetwork(n.id)) != nil { out.NetworksDeleted.append(n.name) }
        }
        return out
    }
}
