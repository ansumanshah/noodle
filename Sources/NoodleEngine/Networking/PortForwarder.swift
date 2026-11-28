import Foundation
import OSLog
import NoodleCore

/// One published port: a host listening socket that relays each connection into the guest.
/// TCP uses a `relay_tcp` stream per connection, UDP a `relay_udp` stream per client address.
final class PortListener: @unchecked Sendable {
    typealias Opener = @Sendable (_ op: String, _ ip: String, _ port: Int) async throws -> GuestStream

    let proto: String        // "tcp" | "udp"
    let hostIP: String
    let hostPort: Int
    let containerIP: String
    let containerPort: Int
    let open: Opener
    let fd: Int32
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.noodle.port")
    let log = Logger(subsystem: "app.noodle", category: "ports")
    let lock = NSLock()
    var udpSessions: [Data: UDPSession] = [:]
    /// Peers whose relay is still being opened; they count against `udpMaxSessions`.
    var udpOpening: Set<Data> = []
    var udpMaxSessions = 256
    var udpIdle: TimeInterval = 60
    var udpTimer: DispatchSourceTimer?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var stopped = false
    private var refusing = false
    let noodleOwned: Bool

    final class UDPSession: @unchecked Sendable {
        let stream: GuestStream
        var lastUsed = Date()
        init(stream: GuestStream) { self.stream = stream }
    }

    /// Bind and start listening. Throws `EngineError.portInUse` like Docker ("port is already allocated").
    /// `noodleOwned` (public-link fronts): the port is claimed before it listens and released at `stop`, so no Mac
    /// loopback relay reaches it. Published container ports leave it false.
    init(proto: String, hostIP: String, hostPort: Int, containerIP: String, containerPort: Int, noodleOwned: Bool = false,
         opener: @escaping Opener) throws {
        self.noodleOwned = noodleOwned
        self.proto = proto; self.hostIP = hostIP.isEmpty ? "0.0.0.0" : hostIP
        self.containerIP = containerIP; self.containerPort = containerPort; self.open = opener

        let isTCP = proto == "tcp"
        let bindIP = self.hostIP
        let isV6 = bindIP.contains(":")
        // SO_REUSEADDR lets a wildcard bind sit beside a Mac listener on 127.0.0.1; Docker refuses that port.
        // Only the IPv4 wildcard checks: the "::" companion would find its own IPv4 sibling answering.
        if isTCP, hostPort != 0, bindIP == "0.0.0.0", NameListener.loopbackAnswers(port: hostPort) {
            throw EngineError.portInUse("Bind for \(bindIP):\(hostPort) failed: port is already allocated")
        }
        let s = socket(isV6 ? AF_INET6 : AF_INET, isTCP ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard s >= 0 else { throw EngineError.portInUse("Bind for \(self.hostIP):\(hostPort) failed: \(String(cString: strerror(errno)))") }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // The IPv4 wildcard has its own listener, so a v6 socket must never claim mapped addresses.
        if isV6 { setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var storage = sockaddr_storage()
        let addrLen = socklen_t(isV6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let parsed: Bool = withUnsafeMutablePointer(to: &storage) { raw in
            if isV6 {
                return raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    a.pointee.sin6_len = UInt8(addrLen); a.pointee.sin6_family = sa_family_t(AF_INET6)
                    a.pointee.sin6_port = UInt16(hostPort).bigEndian
                    return inet_pton(AF_INET6, bindIP, &a.pointee.sin6_addr) == 1
                }
            }
            return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                a.pointee.sin_len = UInt8(addrLen); a.pointee.sin_family = sa_family_t(AF_INET)
                a.pointee.sin_port = UInt16(hostPort).bigEndian
                return inet_pton(AF_INET, bindIP, &a.pointee.sin_addr) == 1
            }
        }
        guard parsed else {
            Darwin.close(s); throw EngineError.invalid("invalid host IP \(hostIP)")
        }
        let rc = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, addrLen) } }
        guard rc == 0 else {
            let e = errno
            Darwin.close(s)
            throw EngineError.portInUse("Bind for \(self.hostIP):\(hostPort) failed: \(e == EADDRINUSE ? "port is already allocated" : String(cString: strerror(e)))")
        }
        var bound = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        // sin_port and sin6_port sit at the same offset.
        self.hostPort = withUnsafeBytes(of: &bound) { Int(UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self))) }
        if noodleOwned { NoodleOwnedPorts.shared.claim(self.hostPort) }
        if isTCP { listen(s, 128) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in isTCP ? self?.acceptReady() : self?.udpReady() }
        let claimed = noodleOwned ? self.hostPort : 0
        src.setCancelHandler { Darwin.close(s); if claimed != 0 { NoodleOwnedPorts.shared.release(claimed) } }
        source = src
        src.resume()
    }

    /// Bind one requested publication. An empty host address means both wildcards on one port, as
    /// Docker does. A Mac without IPv6 keeps the IPv4 listener; a port someone holds on `::` is
    /// refused, or picks another port when the caller did not ask for one.
    static func publish(proto: String, hostIP: String, hostPort: Int, endpoint: EndpointRecord, containerPort: Int, opener: @escaping Opener,
                        created: (PortListener) -> Void) throws -> [PortListener] {
        // A saved container may predate create-time checks; refuse here so the socket code never sees a bad port.
        guard (0...65535).contains(hostPort), (1...65535).contains(containerPort) else {
            throw EngineError.invalid("invalid port mapping \(hostPort):\(containerPort)")
        }
        func make(_ ip: String, _ port: Int) throws -> PortListener {
            guard let target = Engine.publishTarget(hostIP: ip, endpoint) else { throw EngineError.internalError("cannot publish ports without a container address") }
            return try PortListener(proto: proto, hostIP: ip, hostPort: port, containerIP: target, containerPort: containerPort, opener: opener)
        }
        guard hostIP.isEmpty else {
            let l = try make(hostIP, hostPort)
            created(l)
            return [l]
        }
        var attempt = 0
        while true {
            attempt += 1
            let v4 = try make("0.0.0.0", hostPort)
            do {
                let v6 = try make("::", v4.hostPort)
                created(v4); created(v6)
                return [v4, v6]
            } catch EngineError.portInUse(let reason) where !reason.contains("already allocated") {
                created(v4)
                return [v4]
            } catch {
                v4.stop()
                if hostPort != 0 || attempt >= 8 { throw error }
            }
        }
    }

    /// Keep the port bound but refuse every connection and drop the ones in flight. Public links use this so nothing else
    /// can claim the port while a helper that points at it may still be alive; `stop()` releases it afterwards.
    func quiesce() {
        lock.lock()
        refusing = true
        let t = tasks; tasks = [:]
        lock.unlock()
        for (_, task) in t { task.cancel() }
    }

    var isRefusing: Bool { lock.lock(); defer { lock.unlock() }; return refusing }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let t = tasks; tasks = [:]
        let sessions = udpSessions; udpSessions = [:]
        udpTimer?.cancel(); udpTimer = nil
        lock.unlock()
        source?.cancel()
        for (_, task) in t { task.cancel() }
        for (_, s) in sessions { s.stream.close() }
    }

    func track(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.lock()
        if stopped || refusing { lock.unlock(); return }
        tasks[id] = Task { [weak self] in
            await body()
            self?.removeTask(id)
        }
        lock.unlock()
    }

    private func removeTask(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func touch(_ s: UDPSession) { lock.lock(); s.lastUsed = Date(); lock.unlock() }

}
