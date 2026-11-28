import Foundation
import NoodleCore

/// Mac loopback access for containers (protocol.md "Port 1034"). The guest agent relays each TCP connection a
/// container makes to `host.docker.internal` over its own vsock connection; this joins it to the Mac service the way
/// `SSHAgent.serve` joins the agent socket. No process per connection, no timers, nothing on a NIO event loop: the
/// connect runs on its own queue and the bytes flow through `FDChannel` pumps.
final class HostLoopbackRelay: @unchecked Sendable {
    private let paths: NoodlePaths
    private let owned: NoodleOwnedPorts
    private let lock = NSLock()
    /// Open relays and their channels. A relay counts against `maxRelays` from accept until both pumps end.
    private var active: [UUID: [FDChannel]] = [:]
    private let connectQueue = DispatchQueue(label: "app.noodle.hostlo.connect", attributes: .concurrent)
    /// Test seam: runs after a connect succeeds and before ownership is checked again.
    var afterConnect: (@Sendable (UInt16) -> Void)?

    init(paths: NoodlePaths, owned: NoodleOwnedPorts = .shared) {
        self.paths = paths
        self.owned = owned
    }

    var openRelays: Int { lock.lock(); defer { lock.unlock() }; return active.count }

    /// Called on the Virtualization queue with an owned descriptor. Returns at once.
    func serve(guestFD: Int32) {
        let id = UUID()
        lock.lock()
        guard active.count < HostLoopback.maxRelays else { lock.unlock(); Darwin.close(guestFD); return }
        let guest = FDChannel(fd: guestFD, label: "app.noodle.hostlo.guest")
        active[id] = [guest]
        lock.unlock()
        Task {
            await self.relay(guest, id: id)
            self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        lock.lock(); let channels = active.removeValue(forKey: id) ?? []; lock.unlock()
        for c in channels { c.close() }
    }

    /// The VM stopped: end every relay at once. A Mac service that keeps its side open after EOF would otherwise hold a
    /// slot forever. Half-close while the VM runs is unchanged.
    func closeAll() {
        lock.lock(); let all = active; active.removeAll(); lock.unlock()
        for channels in all.values { for c in channels { c.close() } }
    }

    /// Adds the Mac side to a relay still open; false when `closeAll` already ended it.
    private func attach(_ mac: FDChannel, to id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active[id] != nil else { return false }
        active[id]?.append(mac)
        return true
    }

    private func isOwned(_ port: UInt16) -> Bool {
        owned.isNoodleOwned(port, modelPort: HostLoopback.modelSessionPort(root: paths.root))
    }

    private func relay(_ guest: FDChannel, id: UUID) async {
        guard let (request, rest) = await Self.readHeader(guest) else { guest.close(); return }
        let bridge = Self.isMacBridgeAddress(request.gateway)
        var plan = HostLoopback.targets(for: request, noodleOwned: isOwned(request.port), gatewayIsMacBridge: bridge)
        guard var (fd, target) = await connect(plan, port: request.port) else { guest.close(); return }
        afterConnect?(request.port)
        // A Noodle listener may have claimed the port while the connect waited: never hand it a loopback peer.
        if target != .gateway(request.gateway), isOwned(request.port) {
            Darwin.close(fd)
            plan = HostLoopback.targets(for: request, noodleOwned: true, gatewayIsMacBridge: bridge)
            guard let again = await connect(plan, port: request.port) else { guest.close(); return }
            (fd, target) = again
        }
        let mac = FDChannel(fd: fd, label: "app.noodle.hostlo.mac")
        guard attach(mac, to: id) else { mac.close(); guest.close(); return }
        do { if !rest.isEmpty { try await mac.write(rest) } } catch { guest.close(); mac.close(); return }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await SSHAgent.pump(guest, mac) }
            g.addTask { await SSHAgent.pump(mac, guest) }
        }
        guest.close(); mac.close()
    }

    /// The fixed header, then whatever client bytes arrived with it.
    static func readHeader(_ guest: FDChannel) async -> (HostLoopback.Request, Data)? {
        var buffer = Data()
        while buffer.count < HostLoopback.headerSize {
            guard let chunk = try? await guest.read() else { return nil }
            buffer.append(chunk)
        }
        guard let request = HostLoopback.parse(Array(buffer.prefix(HostLoopback.headerSize))) else { return nil }
        return (request, Data(buffer.dropFirst(HostLoopback.headerSize)))
    }

    private func connect(_ plan: [HostLoopback.Target], port: UInt16) async -> (Int32, HostLoopback.Target)? {
        await withCheckedContinuation { (done: CheckedContinuation<(Int32, HostLoopback.Target)?, Never>) in
            connectQueue.async {
                for target in plan {
                    if let fd = Self.connectTCP(target, port: port) { done.resume(returning: (fd, target)); return }
                }
                done.resume(returning: nil)
            }
        }
    }

    /// Non-blocking connect with a 2 s bound. Local targets answer at once; the bound only covers a filtered address.
    static func connectTCP(_ target: HostLoopback.Target, port: UInt16) -> Int32? {
        var storage = sockaddr_storage()
        let length: socklen_t
        switch target {
        case .loopback4, .gateway:
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
            if case .gateway(let ip) = target { a.sin_addr.s_addr = ip } else { a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian }
            withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case .loopback6:
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
            a.sin6_addr = in6addr_loopback
            withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        }
        let fd = socket(Int32(storage.ss_family), SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) } }
        if rc == 0 { return fd }
        guard errno == EINPROGRESS else { Darwin.close(fd); return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 2000) > 0 else { Darwin.close(fd); return nil }
        var err: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l) == 0, err == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// True when `ip` (network order) is assigned to an up `bridge100`-or-above interface: a vmnet NAT link of this Mac.
    static func isMacBridgeAddress(_ ip: UInt32) -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return false }
        defer { freeifaddrs(interfaces) }
        for item in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let i = item.pointee
            guard i.ifa_flags & UInt32(IFF_UP) != 0, let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard strncmp(i.ifa_name, "bridge", 6) == 0, isdigit(Int32(i.ifa_name[6])) != 0, atoi(i.ifa_name + 6) >= 100 else { continue }
            if sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr.s_addr }) == ip { return true }
        }
        return false
    }
}
