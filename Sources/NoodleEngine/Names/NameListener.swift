import Foundation
import NoodleCore

/// Paired IPv4 and IPv6 listening sockets for local names. `.loopback` binds 127.0.0.1 and ::1, which macOS allows below
/// port 1024 only for root. `.wildcard` binds 0.0.0.0 and [::], which an unprivileged user may do on 80 and 443, with
/// IP_BOUND_IF / IPV6_BOUND_IF set to lo0. macOS does not drop inbound traffic from other interfaces for a bound socket
/// (a VM peer still connects), so the barrier is the peer check: a non-loopback peer is closed before a byte is read or written.
/// No timers; nothing runs without a listener.
final class NameListener: @unchecked Sendable {
    enum Scope { case loopback, wildcard }
    /// A failed bind, keeping errno so the router can tell "needs root" (EACCES) from "taken" (EADDRINUSE).
    struct BindError: Error, CustomStringConvertible {
        let code: Int32
        let description: String
    }
    let port: Int
    let scope: Scope
    /// Every successful listener owns both families at the same port.
    let supportsIPv6 = true
    private let sources: [DispatchSourceRead]

    /// Bind (0 picks a port). `onAccept` receives only loopback peers and owns the descriptor.
    init(port: Int, scope: Scope, label: String, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        // SO_REUSEADDR lets a bind sit beside another program's listener on a broader or narrower address; never shadow it.
        if port != 0, Self.loopbackAnswers(port: port) {
            throw BindError(code: EADDRINUSE, description: "port \(port) is in use: \(Self.holder(of: port))")
        }
        let s = try Self.openSocket(family: AF_INET, port: port, scope: scope)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        let selectedPort = Int(UInt16(bigEndian: bound.sin_port))
        // Noodle's own: claimed before anything listens, so no Mac loopback relay can reach the router.
        NoodleOwnedPorts.shared.claim(selectedPort)
        guard listen(s, 64) == 0 else {
            let error = errno; Darwin.close(s); NoodleOwnedPorts.shared.release(selectedPort)
            throw EngineError.internalError("listen: \(String(cString: strerror(error)))")
        }
        // Never advertise ::1 without a real listener. A failed companion bind rolls back IPv4 too,
        // so the router can retry the complete pair at its configured fallback port.
        let s6: Int32
        do {
            s6 = try Self.openSocket(family: AF_INET6, port: selectedPort, scope: scope)
            guard listen(s6, 64) == 0 else {
                let error = errno; Darwin.close(s6)
                throw EngineError.internalError("IPv6 listen: \(String(cString: strerror(error)))")
            }
        } catch { Darwin.close(s); NoodleOwnedPorts.shared.release(selectedPort); throw error }
        self.port = selectedPort
        self.scope = scope
        let queue = DispatchQueue(label: label)
        sources = [s, s6].map { fd in
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler {
                while true {
                    let c = accept(fd, nil, nil)
                    if c < 0 { return }
                    if Self.isLoopback(peer: c) { onAccept(c) } else { Darwin.close(c) }
                }
            }
            source.setCancelHandler { Darwin.close(fd) }
            return source
        }
        for source in sources { source.resume() }
    }

    /// One bound (not yet listening) socket. Wildcard sockets are pinned to lo0 before bind.
    private static func openSocket(family: Int32, port: Int, scope: Scope) throws -> Int32 {
        let v6 = family == AF_INET6
        let s = socket(family, SOCK_STREAM, 0)
        guard s >= 0 else { throw EngineError.internalError("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        func option(_ level: Int32, _ name: Int32, _ value: inout Int32, _ what: String) throws {
            guard setsockopt(s, level, name, &value, size) == 0 else {
                let error = errno; Darwin.close(s)
                throw EngineError.internalError("\(what): \(String(cString: strerror(error)))")
            }
        }
        if v6 { try option(IPPROTO_IPV6, IPV6_V6ONLY, &one, "IPV6_V6ONLY") }
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, size)
        if scope == .wildcard {
            var lo0 = Int32(bitPattern: if_nametoindex("lo0"))
            guard lo0 != 0 else { Darwin.close(s); throw EngineError.internalError("lo0 interface not found") }
            if v6 { try option(IPPROTO_IPV6, IPV6_BOUND_IF, &lo0, "IPV6_BOUND_IF") }
            else { try option(IPPROTO_IP, IP_BOUND_IF, &lo0, "IP_BOUND_IF") }
        }
        let rc: Int32
        if v6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = scope == .wildcard ? in6addr_any : in6addr_loopback
            rc = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = scope == .wildcard ? 0 : UInt32(0x7f000001).bigEndian
            rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard rc == 0 else {
            let e = errno; Darwin.close(s)
            let why = e == EADDRINUSE ? "in use: \(Self.holder(of: port))" : String(cString: strerror(e))
            throw BindError(code: e, description: "\(v6 ? "IPv6 " : "")port \(port) is \(why)")
        }
        return s
    }

    private let stopOnce = NSLock()
    private var stopped = false

    func stop() {
        stopOnce.lock(); let first = !stopped; stopped = true; stopOnce.unlock()
        for source in sources { source.cancel() }
        if first { NoodleOwnedPorts.shared.release(port) }
    }

    /// Accept only peers in 127.0.0.0/8, ::1 or ::ffff:127.0.0.0/104, using the peer's actual address family.
    static func isLoopback(peer c: Int32) -> Bool {
        var address = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(c, $0, &len) }
        }
        guard rc == 0 else { return false }
        let family = address.ss_family
        let bytes: [UInt8] = withUnsafePointer(to: &address) { peer in
            if family == sa_family_t(AF_INET) {
                var ip = peer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                return withUnsafeBytes(of: &ip) { Array($0) }
            }
            if family == sa_family_t(AF_INET6) {
                var ip = peer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                return withUnsafeBytes(of: &ip) { Array($0) }
            }
            return []
        }
        return isLoopback(address: bytes)
    }

    /// Pure check on raw network-order address bytes: 4 bytes for IPv4, 16 for IPv6. Anything else is rejected.
    static func isLoopback(address b: [UInt8]) -> Bool {
        switch b.count {
        case 4: return b[0] == 127
        case 16:
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            return b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff && b[12] == 127
        default: return false
        }
    }

    /// SO_REUSEADDR lets a wildcard bind sit beside a loopback-only listener, so ask the loopback address who answers.
    static func loopbackAnswers(port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian; addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 250) > 0 else { return false }
        var err: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l)
        return err == 0
    }

    /// Name the process listening on `port`, for the message shown when it is taken. Runs only on that failure path.
    static func holder(of port: Int) -> String {
        guard let h = holderInfo(of: port) else { return "held by another process" }
        return "held by \(h.name) (pid \(h.pid))"
    }

    /// The Mac program holding `port`, from lsof. Blocking (3 s cap): call it only off an event loop.
    static func holderInfo(of port: Int, proto: String = "tcp") -> (name: String, pid: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = proto == "udp" ? ["-nP", "-iUDP:\(port)", "-Fcp"] : ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fcp"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit(); killer.cancel()
        return parseLsof(text)
    }

    /// First process in `lsof -Fcp` output that is not `excluding` (this daemon, whose own sockets are not a conflict).
    static func parseLsof(_ text: String, excluding: Int32 = getpid()) -> (name: String, pid: String)? {
        var pid: Substring?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { pid = line.dropFirst() }
            else if line.hasPrefix("c"), let p = pid, Int32(p) != excluding { return (String(line.dropFirst()), String(p)) }
        }
        return nil
    }
}
