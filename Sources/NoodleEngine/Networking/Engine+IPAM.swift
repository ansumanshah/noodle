import Foundation
import NoodleCore

/// Address rules for user networks. The error strings are Docker's: tools match on them.
extension Engine {
    struct ResolvedPool {
        var net: IPv4Net
        var gateway: UInt32
        var range: String?
        var aux: [String: String]?
        var userSubnet: Bool
    }

    /// Nil on an IPv6-only network. Its IPv4 pools are ignored, as Docker does.
    func resolvePool(_ req: NetworkCreateRequest) throws -> ResolvedPool? {
        if req.EnableIPv4 == false { return nil }
        let pools = (req.IPAM.Config ?? []).filter { !Self.isIPv6Pool($0) }
        guard pools.count <= 1 else { throw EngineError.invalid("more than one IPv4 pool on a network is not supported") }
        guard let pool = pools.first, let sub = pool.Subnet, !sub.isEmpty else {
            if let pool = pools.first, pool.Gateway != nil || pool.IPRange != nil || pool.AuxiliaryAddresses != nil {
                throw EngineError.invalid("a gateway, ip-range or aux-address needs a subnet")
            }
            let net = try allocateSubnet()
            return ResolvedPool(net: net, gateway: net.gateway, userSubnet: false)
        }
        guard let net = IPv4Net(cidr: sub) else { throw EngineError.invalid("invalid subnet \(sub)") }
        if networks.values.contains(where: { IPv4Net(cidr: $0.subnet)?.overlaps(net) == true }) {
            throw EngineError.invalid("Pool overlaps with other one on this address space")
        }
        var gateway = net.gateway
        if let g = pool.Gateway, !g.isEmpty {
            guard let v = IPv4Net.parse(g), net.contains(v) else { throw EngineError.invalid("no matching subnet for gateway \(g)") }
            gateway = v
        }
        if let r = pool.IPRange, !r.isEmpty {
            guard let range = IPv4Net(cidr: r, prefixes: 1...32), range.prefix >= net.prefix, net.contains(range.base) else {
                throw EngineError.invalid("no matching subnet for range \(r)")
            }
            // Same bounds IPAM uses: a range that is only the network or broadcast address leaves nothing to lease.
            guard max(range.base, net.base + 1) <= min(range.broadcast, net.broadcast &- 1) else {
                throw EngineError.invalid("no matching subnet for range \(r)")
            }
        }
        for (_, a) in pool.AuxiliaryAddresses ?? [:] {
            guard let v = IPv4Net.parse(a), net.contains(v) else { throw EngineError.invalid("no matching subnet for aux-address \(a)") }
        }
        return ResolvedPool(net: net, gateway: gateway, range: pool.IPRange.flatMap { $0.isEmpty ? nil : $0 },
                            aux: pool.AuxiliaryAddresses.flatMap { $0.isEmpty ? nil : $0 }, userSubnet: true)
    }

    /// The address an endpoint asks for, checked against the network. In-use checks wait for allocation.
    func requestedIP(_ endpoint: EndpointSettings?, on n: NetworkRecord) throws -> String? {
        guard let ip = endpoint?.IPAMConfig?.IPv4Address, !ip.isEmpty else { return nil }
        guard let value = IPv4Net.parse(ip) else { throw EngineError.invalid("invalid IPv4 address: \(ip)") }
        if n.builtin {
            throw EngineError.invalid("user specified IP address is supported on user defined networks only")
        }
        guard n.userSubnet ?? true else {
            throw EngineError.invalid("user specified IP address is supported only when connecting to networks with user configured subnets")
        }
        guard IPv4Net(cidr: n.subnet)?.contains(value) == true else {
            throw EngineError.invalid("no configured subnet or ip-range contain the IP address \(ip)")
        }
        return ip
    }
}
