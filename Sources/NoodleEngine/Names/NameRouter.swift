import Foundation
import NoodleCore

/// Listeners for container and host dev names. They exist only while at least one route has a name. HTTP and HTTPS take the
/// standard ports without root (see `select`), and fall back to uncommon high ports when another program holds them.
/// Host headers select a guest relay for containers or a loopback connection for a host dev server.
final class NameRouter: @unchecked Sendable {
    typealias Opener = PortListener.Opener

    struct Config: Sendable {
        /// Standard ports. 0 skips the standard port and goes straight to the fallback.
        var httpPrimary = 80, httpsPrimary = 443
        /// Ports used when a standard port is taken. Uncommon on purpose, so a user's `-p 8080:80` is never shadowed. 0 picks a free port.
        var httpFallback = 10080, httpsFallback = 10443
    }

    var http: NameListener!
    var https: NameListener?
    var port: Int { http.port }
    var httpsPort: Int? { https?.port }
    /// Why a standard port was not used, per scheme ("http", "https"). Empty when both got their standard port.
    private(set) var fallbacks: [String: String] = [:]
    /// Set when HTTPS could not be bound at all.
    private(set) var httpsOff: String?
    let dns: LocalNameDNS
    let identities: NameIdentities
    let lock = NSLock()
    var targets: [String: LocalNames.Target] = [:]
    var openers: [String: Opener] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    var clients: [UUID: FDChannel] = [:]
    struct DevRoute {
        let token: String
        let host: String
        let port: Int
        let ownerPID: Int32
        let exit: DispatchSourceProcess
    }
    var devRoutes: [String: DevRoute] = [:]
    let onDevChange: @Sendable () -> Void
    var stopped = false

    /// Throws only when no HTTP port at all could be bound. HTTPS is optional: its absence is reported in `notices`.
    init(config: Config, ca: LocalCA, onDevChange: @escaping @Sendable () -> Void = {}) throws {
        dns = LocalNameDNS(onChange: onDevChange)
        identities = NameIdentities(ca: ca)
        self.onDevChange = onDevChange
        http = try bind(primary: config.httpPrimary, fallback: config.httpFallback, label: "HTTP") { [weak self] fd in self?.accept(fd, tls: false) }
        do { https = try bind(primary: config.httpsPrimary, fallback: config.httpsFallback, label: "HTTPS") { [weak self] fd in self?.accept(fd, tls: true) } }
        catch { httpsOff = "\(error)" }
        // Both listener pairs must exist before publishing IPv6 loopback destinations.
        if http.supportsIPv6, https?.supportsIPv6 == true { dns.enableIPv6() }
        // Create the authority off the caller's thread so `noodle names trust` and the first handshake find it ready.
        if https != nil { let ids = identities; DispatchQueue.global(qos: .utility).async { ids.prepare() } }
    }

    private func bind(primary: Int, fallback: Int, label: String, onAccept: @escaping @Sendable (Int32) -> Void) throws -> NameListener {
        let name = "app.noodle.names.\(label.lowercased())"
        let (listener, reason) = try Self.select(primary: primary, fallback: fallback) { port, scope in
            try NameListener(port: port, scope: scope, label: name, onAccept: onAccept)
        }
        if let reason { fallbacks[label.lowercased()] = reason }
        return listener
    }

    /// Bind order for one scheme. Each port tries loopback addresses first (root may bind them below 1024); EACCES there
    /// retries the wildcard pinned to lo0, which needs no root. A taken or failed primary moves to the fallback port.
    /// Returns the listener and, when the primary was not used, why.
    static func select<L>(primary: Int, fallback: Int, open: (Int, NameListener.Scope) throws -> L) throws -> (L, String?) {
        func attempt(_ port: Int) throws -> L {
            do { return try open(port, .loopback) }
            catch let error as NameListener.BindError where error.code == EACCES { return try open(port, .wildcard) }
        }
        var reason: String?
        if primary != 0 {
            do { return (try attempt(primary), nil) } catch { reason = "\(error)" }
        }
        do { return (try attempt(fallback), reason) }
        catch { throw EngineError.portInUse([reason, "\(error)"].compactMap { $0 }.joined(separator: "; ")) }
    }
}
