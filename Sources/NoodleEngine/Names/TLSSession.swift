import Darwin
import Foundation
import Network
import Security

/// TLS 1.2/1.3 through Network.framework. Its public API cannot adopt an accepted socket, so each session uses a
/// loopback TLS listener restricted to its own relay socket. The router receives an ordinary HTTP/1.1 byte stream,
/// including unchanged WebSocket traffic after an upgrade. No TLS implementation or dependency is bundled.
final class TLSSession: @unchecked Sendable {
    let tls: Int32
    private let identities: NameIdentities
    private let allowed: @Sendable (String) -> Bool
    private let onPlain: @Sendable (Int32) -> Void
    let queue = DispatchQueue(label: "app.noodle.names.tls.network")
    // Callback state is confined to queue; the encrypted relay thread reads it through queue.sync.
    private var listener: NWListener?
    private var connection: NWConnection?
    private var plaintext: PlaintextRelay?
    var ready = false, failed = false, stopped = false
    private var wakeWrite: Int32 = -1
    static let cap = 1 << 20
    /// Each handshake holds a thread and a loopback listener, so a burst of local connections is bounded:
    /// past the limit a new connection is closed at once, with no queue behind it.
    static let maxConcurrent = 32
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = 0

    /// Claims a slot, or returns false when the limit is reached.
    static func claimSlot(limit: Int = maxConcurrent) -> Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        guard active < limit else { return false }
        active += 1
        return true
    }
    static func releaseSlot() { activeLock.lock(); active -= 1; activeLock.unlock() }

    /// Takes ownership of fd. onPlain owns its descriptor once the TLS handshake has succeeded.
    static func start(fd: Int32, identities: NameIdentities, allowed: @escaping @Sendable (String) -> Bool, onPlain: @escaping @Sendable (Int32) -> Void) {
        guard claimSlot() else { Darwin.close(fd); return }
        let session = TLSSession(fd: fd, identities: identities, allowed: allowed, onPlain: onPlain)
        let thread = Thread { defer { session.releaseHandshakeSlot() }; session.run() }
        thread.name = "app.noodle.names.tls"; thread.stackSize = 256 * 1024; thread.start()
    }

    /// The cap bounds handshakes: the slot goes back once the handshake is ready or failed, and at thread end otherwise.
    private let slotLock = NSLock()
    private var slotHeld = true
    private func releaseHandshakeSlot() {
        slotLock.lock(); defer { slotLock.unlock() }
        if slotHeld { slotHeld = false; Self.releaseSlot() }
    }

    private init(fd: Int32, identities: NameIdentities, allowed: @escaping @Sendable (String) -> Bool, onPlain: @escaping @Sendable (Int32) -> Void) {
        tls = fd; self.identities = identities; self.allowed = allowed; self.onPlain = onPlain
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func run() {
        defer { Darwin.close(tls) }
        Self.configure(tls)
        let deadline = DispatchTime.now() + .seconds(10)
        guard let hello = clientHello(deadline: deadline), allowed(hello.host),
              let identity = try? identities.identity(for: hello.host), let secIdentity = sec_identity_create(identity) else { return }
        let local = socket(AF_INET, SOCK_STREAM, 0)
        guard local >= 0 else { return }
        defer { Darwin.close(local) }
        Self.configure(local)
        // Reserve the source port before listening. No other socket can connect with this reserved TCP tuple.
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &address, { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(local, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }) == 0 else { return }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(local, $0, &addressLength)
        } }) == 0 else { return }
        let sourcePort = UInt16(bigEndian: address.sin_port)
        var wake: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &wake) == 0 else { return }
        wake.forEach(Self.configure)
        queue.sync { wakeWrite = wake[1] }
        defer {
            queue.sync {
                stopped = true
                plaintext?.stop(); plaintext = nil
                connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
                listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
                listener?.cancel(); listener = nil; wakeWrite = -1
            }
            Darwin.close(wake[0]); Darwin.close(wake[1])
        }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, false)
        // NameRouter parses HTTP/1.1; h2 cannot be advertised until it can route HTTP/2 frames.
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server: NWListener
        do { server = try NWListener(using: parameters) } catch { return }
        let listening = DispatchSemaphore(value: 0)
        queue.sync {
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: listening.signal()
                case .failed: self.fail(); listening.signal()
                default: break
                }
            }
            server.newConnectionHandler = { [weak self] incoming in
                guard let self, !self.stopped, self.connection == nil,
                      case let .hostPort(host, port) = incoming.endpoint,
                      host == .ipv4(.loopback), port.rawValue == sourcePort else { incoming.cancel(); return }
                self.connection = incoming
                server.cancel()
                incoming.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready:
                        guard !self.ready else { return }
                        self.ready = true; self.releaseHandshakeSlot(); self.openPlaintext(incoming); self.signal()
                    case .failed: self.fail()
                    default: break
                    }
                }
                incoming.start(queue: self.queue)
            }
            server.start(queue: queue)
        }
        guard listening.wait(timeout: deadline) == .success,
              let port = queue.sync(execute: { failed ? nil : server.port }) else { return }
        address.sin_port = port.rawValue.bigEndian
        let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(local, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        if connected != 0 {
            guard errno == EINPROGRESS, wait(local, events: Int16(POLLOUT), deadline: deadline) else { return }
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(local, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return }
        }
        pump(local: local, wake: wake[0], prefix: hello.wire, deadline: deadline)
    }

    private func signal() {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }
    private func fail() { failed = true; releaseHandshakeSlot(); connection?.cancel(); signal() }

    private func openPlaintext(_ incoming: NWConnection) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fail(); return }
        Self.configure(pair[0]); Self.configure(pair[1])
        let relay = PlaintextRelay(fd: pair[1], connection: incoming, queue: queue)
        plaintext = relay; relay.start(); onPlain(pair[0])
    }

}
