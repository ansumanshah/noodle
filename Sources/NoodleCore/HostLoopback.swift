import Foundation

/// The Mac loopback relay contract and its policy (docs/architecture/protocol.md "Port 1034").
/// Pure: parsing and target choice only, so the hostile cases are unit tested without a VM.
public enum HostLoopback {
    /// Host listens, main VM only. The agent dials it once per relayed container connection.
    public static let vsockPort: UInt32 = 1034
    /// Control op that starts the guest side.
    public static let guestOp = "host_loopback"
    public static let headerSize = 8
    /// Open relays at once, per side. One more is closed without a byte.
    public static let maxRelays = 64
    /// The model server's default port. Always treated as Noodle's own.
    public static let modelServerPort: UInt16 = 11345

    public struct Request: Equatable, Sendable {
        public let port: UInt16
        /// The IPv4 address the container dialled, in network byte order: the Mac's end of the NAT link.
        public let gateway: UInt32
        public init(port: UInt16, gateway: UInt32) { self.port = port; self.gateway = gateway }
    }

    /// The header is data from the guest: anything other than version 1, family 4 and a nonzero port is refused.
    public static func parse(_ bytes: [UInt8]) -> Request? {
        guard bytes.count == headerSize, bytes[0] == 1, bytes[1] == 4 else { return nil }
        let port = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard port != 0 else { return nil }
        let gateway = bytes[4...7].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Request(port: port, gateway: gateway)
    }

    public static func header(_ r: Request) -> [UInt8] {
        var out: [UInt8] = [1, 4, UInt8(r.port >> 8), UInt8(r.port & 0xff)]
        withUnsafeBytes(of: r.gateway) { out.append(contentsOf: $0) }
        return out
    }

    public enum Target: Equatable, Sendable {
        case loopback4
        case loopback6
        /// The header address, network byte order.
        case gateway(UInt32)
    }

    /// Where the host connects, in order. A Noodle-owned port keeps only the NAT path it had before the relay existed,
    /// and the NAT path is offered only when the header names a Mac VM bridge address.
    public static func targets(for r: Request, noodleOwned: Bool, gatewayIsMacBridge: Bool) -> [Target] {
        var out: [Target] = noodleOwned ? [] : [.loopback4, .loopback6]
        if gatewayIsMacBridge { out.append(.gateway(r.gateway)) }
        return out
    }

    /// The model server's recorded port, `models/session.json` key `port`, when a session exists.
    public static func modelSessionPort(root: URL) -> UInt16? {
        let file = root.appendingPathComponent("models", isDirectory: true).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let value = UInt16(exactly: port), value != 0 else { return nil }
        return value
    }
}

/// Loopback ports Noodle itself listens on (Finder server, public-link fronts, local names, model servers). Listeners
/// claim their port before they listen; every relay refuses claimed ports. Claims are files in one per-user directory,
/// `<dir>/<port>/<pid>`, so a daemon with another `NOODLE_HOME`, or a model server started from any home, protects its
/// port from every other daemon's relay too. A claim whose process is gone is ignored and pruned. In-process claims are
/// counted, because two listeners may share a port over time.
public final class NoodleOwnedPorts: @unchecked Sendable {
    /// `~/Library/Application Support/Noodle/loopback-claims`, the same for every daemon of this user.
    public static let shared = NoodleOwnedPorts(directory: defaultDirectory)
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Noodle/loopback-claims", isDirectory: true)
    }

    public let directory: URL
    private let pid: Int32
    private let lock = NSLock()
    private var counts: [UInt16: Int] = [:]

    public init(directory: URL, pid: Int32 = getpid()) {
        self.directory = directory
        self.pid = pid
    }

    private func file(_ port: UInt16, _ owner: Int32) -> URL {
        directory.appendingPathComponent(String(port), isDirectory: true).appendingPathComponent(String(owner))
    }

    public func claim(_ port: Int) {
        guard let p = UInt16(exactly: port), p != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        counts[p, default: 0] += 1
        guard counts[p] == 1 else { return }
        Self.write(file(p, pid))
    }

    /// Claim on behalf of another live process (the model server execs from the CLI with this pid).
    public func claim(_ port: Int, forProcess owner: Int32) {
        guard let p = UInt16(exactly: port), p != 0 else { return }
        Self.write(file(p, owner))
    }

    private static func write(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    public func release(_ port: Int) {
        guard let p = UInt16(exactly: port), p != 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let n = counts[p] else { return }
        counts[p] = n > 1 ? n - 1 : nil
        if n == 1 { try? FileManager.default.removeItem(at: file(p, pid)) }
    }

    /// Claimed by this process, or by any live process of this user.
    public func contains(_ port: UInt16) -> Bool {
        lock.lock(); let mine = counts[port] != nil; lock.unlock()
        if mine { return true }
        let dir = directory.appendingPathComponent(String(port), isDirectory: true)
        guard let owners = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        for name in owners {
            guard let owner = Int32(name), owner > 0 else { continue }
            if owner != pid, kill(owner, 0) == 0 || errno == EPERM { return true }
            if owner != pid { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
        return false
    }

    /// Owned now: a claimed listener, the model server default, or the model server's recorded port.
    public func isNoodleOwned(_ port: UInt16, modelPort: UInt16?) -> Bool {
        port == HostLoopback.modelServerPort || port == modelPort || contains(port)
    }
}
