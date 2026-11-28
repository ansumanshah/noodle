import Foundation
import NoodleCore
import Security

/// Lifetime belongs to the private API route table. Construction starts no tasks or sockets.
public actor FinderServer {
    public struct Status: Encodable, Sendable {
        public var url: String?
        public var mounted: Bool
        public var mountpoint: String?
    }
    private struct Session: Sendable {
        let token: String
        let port: Int
        var mountpoint: String?
        var url: String { "http://127.0.0.1:\(port)/\(token)/" }
    }
    private let engine: Engine
    private var listener: FinderServerListener?
    private var session: Session?
    private var stopping = false
    private var connections: [UUID: (FinderServerConnection, Task<Void, Never>)] = [:]

    public init(engine: Engine) { self.engine = engine }

    public func status() -> Status {
        Status(url: session?.url, mounted: session.map { Self.mounted($0) } ?? false, mountpoint: session?.mountpoint)
    }

    public func start(mountpoint: String?) throws -> Status {
        guard !stopping else { throw EngineError.conflict("Finder view is stopping") }
        if var current = session {
            if current.mountpoint != mountpoint {
                guard !Self.mounted(current) else { throw EngineError.conflict("Finder view is already mounted") }
                current.mountpoint = mountpoint
                session = current
            }
            return status()
        }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw EngineError.internalError("could not create Finder capability")
        }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let listener = try FinderServerListener { [weak self] fd, release in
            guard let self else { Darwin.close(fd); release(); return }
            Task { await self.accept(fd, release: release) }
        }
        self.listener = listener
        session = Session(token: token, port: listener.port, mountpoint: mountpoint)
        return status()
    }

    public func stop() async throws -> Status {
        guard !stopping else { throw EngineError.conflict("Finder view is stopping") }
        if let session, Self.mounted(session) { throw EngineError.conflict("unmount the Finder filesystem first") }
        stopping = true
        let listener = self.listener
        self.listener = nil
        session = nil
        let active = connections
        connections = [:]
        for (_, (client, task)) in active { client.close(); task.cancel() }
        await listener?.stop()
        // Await cancellation so no guest stream survives a successful stop response.
        for (_, (_, task)) in active { await task.value }
        stopping = false
        return status()
    }

    func accept(_ fd: Int32, release: @escaping @Sendable () -> Void) {
        guard let session, !stopping, connections.count < 8 else { Darwin.close(fd); release(); return }
        guard let client = FinderServerConnection(FDChannel(fd: fd, label: "app.noodle.finder")) else { release(); return }
        let id = UUID(), engine = self.engine
        let task = Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withTaskCancellationHandler {
                        await FinderHTTP.serve(client, engine: engine, token: session.token, port: session.port)
                    } onCancel: { client.close() }
                }
                group.addTask {
                    await client.closeWhenIdle()
                }
                _ = await group.next()
                group.cancelAll()
            }
            client.close()
            release()
            await self?.finished(id)
        }
        connections[id] = (client, task)
    }

    private func finished(_ id: UUID) { connections[id] = nil }

    /// Read the cached mount table, never stat a potentially unresponsive WebDAV path.
    private static func mounted(_ session: Session) -> Bool {
        guard let path = session.mountpoint else { return false }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0, count <= 4096 else { return false }
        let capacity = Int(count)
        let mounts = Array<statfs>(unsafeUninitializedCapacity: capacity) { buffer, initialized in
            let actual = getfsstat(buffer.baseAddress, Int32(capacity * MemoryLayout.size(ofValue: statfs())), MNT_NOWAIT)
            initialized = actual > 0 ? min(Int(actual), capacity) : 0
        }
        guard !mounts.isEmpty else { return false }
        for var mount in mounts {
            let name = withUnsafeBytes(of: &mount.f_fstypename) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let target = withUnsafeBytes(of: &mount.f_mntonname) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "webdav", target == path { return true }
        }
        return false
    }
}

/// Owns a strictly loopback socket. Stop completes only after the descriptor is closed.
private final class FinderServerListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "app.noodle.finder.accept")
    init(accept onAccept: @escaping @Sendable (Int32, @escaping @Sendable () -> Void) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.internalError("Finder socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw EngineError.internalError("Finder bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            Darwin.close(fd); throw EngineError.internalError("Finder socket setup failed")
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        // Noodle's own: claimed before it listens, so no Mac loopback relay reaches it. Released on close.
        NoodleOwnedPorts.shared.claim(port)
        guard listen(fd, 8) == 0 else {
            Darwin.close(fd); NoodleOwnedPorts.shared.release(port); throw EngineError.internalError("Finder listen failed")
        }
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let slots = DispatchSemaphore(value: 8)
        source.setEventHandler {
            // Yield the accept queue even under a local connection flood so stop
            // cannot be starved by a perpetually readable listening socket.
            for _ in 0..<32 {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }
                // This check runs before constructing a reader or writing any response.
                guard NameListener.isLoopback(peer: client), slots.wait(timeout: .now()) == .success else {
                    Darwin.close(client); continue
                }
                onAccept(client, { slots.signal() })
            }
        }
        let claimed = port
        source.setCancelHandler { Darwin.close(fd); NoodleOwnedPorts.shared.release(claimed) }
        source.resume()
    }
    func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [source, fd, port] in
                // Append a completion handler without losing ownership of the close.
                source.setCancelHandler { Darwin.close(fd); NoodleOwnedPorts.shared.release(port); done.resume() }
                source.cancel()
            }
        }
    }
    deinit { source.cancel() }
}
