import Foundation
import NoodleCore
import NoodleImages

// MARK: IPv4 math

struct IPv4Net: Equatable {
    var base: UInt32
    var prefix: Int

    init?(cidr: String, prefixes: ClosedRange<Int> = 8...30) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let p = Int(parts[1]), prefixes.contains(p), let a = IPv4Net.parse(String(parts[0])) else { return nil }
        prefix = p
        base = a & IPv4Net.mask(p)
    }
    init(base: UInt32, prefix: Int) { self.base = base; self.prefix = prefix }

    static func mask(_ p: Int) -> UInt32 { p == 0 ? 0 : ~UInt32(0) << UInt32(32 - p) }
    static func parse(_ s: String) -> UInt32? {
        let o = s.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4, s.split(separator: ".").count == 4 else { return nil }
        return UInt32(o[0]) << 24 | UInt32(o[1]) << 16 | UInt32(o[2]) << 8 | UInt32(o[3])
    }
    static func string(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)" }

    var cidr: String { "\(IPv4Net.string(base))/\(prefix)" }
    var gateway: UInt32 { base + 1 }
    var broadcast: UInt32 { base | ~IPv4Net.mask(prefix) }
    func contains(_ ip: UInt32) -> Bool { ip & IPv4Net.mask(prefix) == base }
    func overlaps(_ o: IPv4Net) -> Bool { contains(o.base) || o.contains(base) }
}

/// Address pool. Leases live in memory only: they die with the VM, which is when every container stops.
struct IPAM {
    var net: IPv4Net
    var gateway: UInt32
    var leases: [UInt32: String] = [:]
    var cursor: UInt32
    /// Dynamic addresses come from here. A requested address only has to be in the subnet.
    var first: UInt32
    var last: UInt32
    var reserved: Set<UInt32> = []
    /// `name (id)`, for the exhaustion error.
    var label: String

    init(net: IPv4Net, gateway: UInt32?, range: IPv4Net? = nil, reserved: Set<UInt32> = [], label: String = "") {
        self.net = net
        self.gateway = gateway ?? net.gateway
        self.reserved = reserved
        self.label = label
        let usable = net.base + 1...max(net.base + 1, net.broadcast - 1)
        first = max(range?.base ?? 0, usable.lowerBound)
        last = min(range?.broadcast ?? .max, usable.upperBound)
        cursor = first
    }

    private func isFree(_ ip: UInt32) -> Bool { ip != gateway && !reserved.contains(ip) && leases[ip] == nil }

    mutating func allocate(for container: String, preferred: UInt32? = nil) throws -> UInt32 {
        if let p = preferred {
            guard net.contains(p) else {
                throw EngineError.invalid("no configured subnet or ip-range contain the IP address \(IPv4Net.string(p))")
            }
            if leases[p] == container { return p }
            guard isFree(p), p != net.base, p != net.broadcast else { throw EngineError.conflict("Address already in use") }
            leases[p] = container
            return p
        }
        if let existing = leases.first(where: { $0.value == container })?.key { return existing }
        guard first <= last else {
            throw EngineError.internalError("no available IPv4 addresses on this network's address pools: \(label)")
        }
        var candidate = max(cursor, first)
        for _ in 0...(last - first) {
            if candidate > last { candidate = first }
            if isFree(candidate) {
                leases[candidate] = container
                cursor = candidate + 1
                return candidate
            }
            candidate += 1
        }
        throw EngineError.internalError("no available IPv4 addresses on this network's address pools: \(label)")
    }

    mutating func release(container: String) {
        for (ip, owner) in leases where owner == container { leases[ip] = nil }
    }
}

enum MAC {
    /// Docker style: 02:42 + the four IPv4 octets.
    static func forIP(_ ip: UInt32) -> String {
        String(format: "02:42:%02x:%02x:%02x:%02x", ip >> 24 & 255, ip >> 16 & 255, ip >> 8 & 255, ip & 255)
    }
}
