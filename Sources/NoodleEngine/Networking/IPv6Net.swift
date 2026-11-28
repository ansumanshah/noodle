import Foundation

/// One IPv6 address as two big-endian halves, so the arithmetic stays plain.
struct IPv6Addr: Hashable, Comparable {
    var hi: UInt64
    var lo: UInt64

    init(hi: UInt64, lo: UInt64) { self.hi = hi; self.lo = lo }

    init?(_ text: String) {
        guard text.contains(":"), !text.contains("%") else { return nil }
        var raw = in6_addr()
        guard inet_pton(AF_INET6, text, &raw) == 1 else { return nil }
        let (h, l) = withUnsafeBytes(of: raw) { p in
            (p.loadUnaligned(fromByteOffset: 0, as: UInt64.self), p.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        hi = UInt64(bigEndian: h); lo = UInt64(bigEndian: l)
    }

    /// The canonical short form, the one Docker prints.
    var string: String {
        var raw = (hi.bigEndian, lo.bigEndian)
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = withUnsafeBytes(of: &raw) { inet_ntop(AF_INET6, $0.baseAddress, &out, socklen_t(out.count)) }
        return String(cString: out)
    }

    static func < (a: IPv6Addr, b: IPv6Addr) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }

    func next() -> IPv6Addr {
        lo == .max ? IPv6Addr(hi: hi &+ 1, lo: 0) : IPv6Addr(hi: hi, lo: lo + 1)
    }
}

struct IPv6Net: Equatable {
    var base: IPv6Addr
    var prefix: Int

    init(base: IPv6Addr, prefix: Int) { self.base = base; self.prefix = prefix }

    init?(cidr: String, prefixes: ClosedRange<Int> = 8...126) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let p = Int(parts[1]), prefixes.contains(p), let a = IPv6Addr(String(parts[0])) else { return nil }
        prefix = p
        base = IPv6Net.masked(a, p)
    }

    static func masked(_ a: IPv6Addr, _ p: Int) -> IPv6Addr {
        let hiMask: UInt64 = p >= 64 ? .max : (p == 0 ? 0 : ~UInt64(0) << UInt64(64 - p))
        let loMask: UInt64 = p <= 64 ? 0 : (p >= 128 ? .max : ~UInt64(0) << UInt64(128 - p))
        return IPv6Addr(hi: a.hi & hiMask, lo: a.lo & loMask)
    }

    var cidr: String { "\(base.string)/\(prefix)" }
    var gateway: IPv6Addr { base.next() }
    var last: IPv6Addr {
        let m = IPv6Net.masked(IPv6Addr(hi: .max, lo: .max), prefix)
        return IPv6Addr(hi: base.hi | ~m.hi, lo: base.lo | ~m.lo)
    }
    func contains(_ a: IPv6Addr) -> Bool { IPv6Net.masked(a, prefix) == base }
    func overlaps(_ o: IPv6Net) -> Bool { contains(o.base) || o.contains(base) }
}

/// The IPv6 half of a network's pool. Like `IPAM`, leases live in memory and die with the VM.
struct IPAM6 {
    var net: IPv6Net
    var gateway: IPv6Addr
    var leases: [IPv6Addr: String] = [:]
    var reserved: Set<IPv6Addr>
    var first: IPv6Addr
    var last: IPv6Addr
    var cursor: IPv6Addr
    var label: String

    init(net: IPv6Net, gateway: IPv6Addr?, range: IPv6Net? = nil, reserved: Set<IPv6Addr> = [], label: String = "") {
        self.net = net
        self.gateway = gateway ?? net.gateway
        self.reserved = reserved
        self.label = label
        first = max(range?.base ?? net.base.next(), net.base.next())
        last = min(range?.last ?? net.last, net.last)
        cursor = first
    }

    private func isFree(_ a: IPv6Addr) -> Bool { a != gateway && a != net.base && !reserved.contains(a) && leases[a] == nil }

    mutating func allocate(for container: String, preferred: IPv6Addr? = nil) throws -> IPv6Addr {
        if let p = preferred {
            guard net.contains(p) else {
                throw EngineError.invalid("no configured subnet or ip-range contain the IP address \(p.string)")
            }
            if leases[p] == container { return p }
            guard isFree(p) else { throw EngineError.conflict("Address already in use") }
            leases[p] = container
            return p
        }
        if let existing = leases.first(where: { $0.value == container })?.key { return existing }
        // A pool can be 2^64 wide, so stop after as many tries as could possibly be taken.
        var candidate = max(cursor, first)
        for _ in 0...(leases.count + reserved.count + 1) {
            if candidate > last { candidate = first }
            if isFree(candidate) {
                leases[candidate] = container
                cursor = candidate.next()
                return candidate
            }
            candidate = candidate.next()
        }
        throw EngineError.internalError("no available IPv6 addresses on this network's address pools: \(label)")
    }

    mutating func release(container: String) {
        for (a, owner) in leases where owner == container { leases[a] = nil }
    }
}
