import Foundation
import NoodleCore

/// IPv6 address rules for user networks. Bucket: dual stack. The error strings follow Docker's.
extension Engine {
    /// Automatic pools: one /64 per network from a fixed ULA /48. Every network sits behind the VM's
    /// NAT66, so no two engines ever need to route to each other.
    static let ula48 = IPv6Addr(hi: 0xfd6e_6f6f_646c_0000, lo: 0)

    struct ResolvedPool6 {
        var net: IPv6Net
        var gateway: IPv6Addr
        var range: String?
        var aux: [String: String]?
        var userSubnet: Bool
    }

    static func isIPv6Pool(_ p: IPAMPool) -> Bool {
        (p.Subnet ?? p.Gateway ?? p.IPRange ?? "").contains(":")
    }

    func allocateSubnet6() throws -> IPv6Net {
        let used = networks.values.compactMap { $0.subnet6.flatMap { IPv6Net(cidr: $0) } }
        for id in UInt64(1)...0xffff {
            let c = IPv6Net(base: IPv6Addr(hi: Self.ula48.hi | id, lo: 0), prefix: 64)
            if !used.contains(where: { $0.overlaps(c) }) { return c }
        }
        throw EngineError.internalError("could not find an available, non-overlapping IPv6 address pool among the defaults to assign to the network")
    }

    /// Nil when the network has no IPv6. A v6 pool on a network without `--ipv6` is ignored, as Docker does.
    func resolvePool6(_ req: NetworkCreateRequest) throws -> ResolvedPool6? {
        guard req.EnableIPv6 else { return nil }
        let pools = (req.IPAM.Config ?? []).filter(Self.isIPv6Pool)
        guard pools.count <= 1 else { throw EngineError.invalid("more than one IPv6 pool on a network is not supported") }
        guard let pool = pools.first else {
            let net = try allocateSubnet6()
            return ResolvedPool6(net: net, gateway: net.gateway, userSubnet: false)
        }
        guard let sub = pool.Subnet, !sub.isEmpty else { throw EngineError.invalid("a gateway, ip-range or aux-address needs a subnet") }
        guard let net = IPv6Net(cidr: sub) else { throw EngineError.invalid("invalid subnet \(sub)") }
        if networks.values.contains(where: { $0.subnet6.flatMap { IPv6Net(cidr: $0) }?.overlaps(net) == true }) {
            throw EngineError.invalid("Pool overlaps with other one on this address space")
        }
        var gateway = net.gateway
        if let g = pool.Gateway, !g.isEmpty {
            guard let v = IPv6Addr(g), net.contains(v) else { throw EngineError.invalid("no matching subnet for gateway \(g)") }
            gateway = v
        }
        if let r = pool.IPRange, !r.isEmpty {
            guard let range = IPv6Net(cidr: r, prefixes: 1...128), range.prefix >= net.prefix, net.contains(range.base) else {
                throw EngineError.invalid("no matching subnet for range \(r)")
            }
        }
        for (_, a) in pool.AuxiliaryAddresses ?? [:] {
            guard let v = IPv6Addr(a), net.contains(v) else { throw EngineError.invalid("no matching subnet for aux-address \(a)") }
        }
        return ResolvedPool6(net: net, gateway: gateway, range: pool.IPRange.flatMap { $0.isEmpty ? nil : $0 },
                             aux: pool.AuxiliaryAddresses.flatMap { $0.isEmpty ? nil : $0 }, userSubnet: true)
    }

    func requestedIP6(_ endpoint: EndpointSettings?, on n: NetworkRecord) throws -> String? {
        guard let ip = endpoint?.IPAMConfig?.IPv6Address, !ip.isEmpty else { return nil }
        guard let value = IPv6Addr(ip) else { throw EngineError.invalid("invalid IPv6 address: \(ip)") }
        if n.builtin { throw EngineError.invalid("user specified IP address is supported on user defined networks only") }
        guard let sub = n.subnet6.flatMap({ IPv6Net(cidr: $0) }), sub.contains(value) else {
            throw EngineError.invalid("no configured subnet or ip-range contain the IP address \(ip)")
        }
        guard n.userSubnet6 ?? true else {
            throw EngineError.invalid("user specified IP address is supported only when connecting to networks with user configured subnets")
        }
        return value.string
    }

    func ipam6(_ net: NetworkRecord) -> IPAM6? {
        if let p = ipams6[net.id] { return p }
        guard let cidr = net.subnet6.flatMap({ IPv6Net(cidr: $0) }) else { return nil }
        let p = IPAM6(net: cidr, gateway: net.gateway6.flatMap { IPv6Addr($0) },
                      range: net.ipRange6.flatMap { IPv6Net(cidr: $0, prefixes: 1...128) },
                      reserved: Set((net.auxAddresses6 ?? [:]).values.compactMap { IPv6Addr($0) }), label: "\(net.name) (\(net.id))")
        ipams6[net.id] = p
        return p
    }

    /// Give up everything a container holds on one network.
    func releaseAddresses(network id: String, container: String) {
        ipams[id]?.release(container: container)
        ipams6[id]?.release(container: container)
    }

    /// Read the three supported disable_ipv6 overrides before allocating endpoint addresses.
    static func disablesIPv6(_ c: ContainerRecord) -> Bool {
        let sysctls = c.hostConfig.Sysctls ?? [:]
        return ["all", "default", "eth0"].contains { sysctls["net.ipv6.conf.\($0).disable_ipv6"] == "1" }
    }

    /// The guest arguments that say which addresses an endpoint has on a secondary network.
    func netConnectArgs(_ n: NetworkRecord, container id: String, _ e: EndpointRecord) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["network": .string(n.name), "container": .string(id), "ip": .string(e.ip),
                                         "mac": .string(e.mac), "aliases": .strings(e.aliases)]
        if let ip6 = e.ip6 { args["ip6"] = .string(ip6) }
        return args
    }

    /// Where a published port's traffic goes: the same family as the host address, or across when
    /// the container only has the other one.
    static func publishTarget(hostIP: String, _ e: EndpointRecord?) -> String? {
        guard let e else { return nil }
        let v4 = e.ip.isEmpty ? nil : e.ip
        return hostIP.contains(":") ? (e.ip6 ?? v4) : (v4 ?? e.ip6)
    }
}
