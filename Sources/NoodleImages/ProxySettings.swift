import Foundation

/// Proxy choice for registry traffic (and, optionally, for new containers). On-demand: nothing runs unless a proxy is set.
public struct ProxySettings: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case system, custom, off }
    public var mode: Mode
    /// `http://[user:password@]host:port`. Used when `mode == .custom`.
    public var url: String?
    /// Hosts that skip the custom proxy: `host`, `.domain`, `*.domain`, an IPv4 address, an IPv4 CIDR, or `*`.
    public var exceptions: [String]
    /// Add `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` to new containers that do not set them. Credentials are never injected.
    public var injectIntoContainers: Bool

    public static let redactedPassword = "***"

    public init(mode: Mode = .system, url: String? = nil, exceptions: [String] = [], injectIntoContainers: Bool = false) {
        self.mode = mode; self.url = url; self.exceptions = exceptions; self.injectIntoContainers = injectIntoContainers
    }

    /// Fields other than `mode` may be left out of a request or an older stored file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .system
        url = try c.decodeIfPresent(String.self, forKey: .url)
        exceptions = try c.decodeIfPresent([String].self, forKey: .exceptions) ?? []
        injectIntoContainers = try c.decodeIfPresent(Bool.self, forKey: .injectIntoContainers) ?? false
    }

    public struct Endpoint: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var user: String?
        public var password: String?
    }

    /// The custom proxy, or nil when the mode is not custom or the URL is unusable.
    public var endpoint: Endpoint? {
        guard mode == .custom, let url, let c = URLComponents(string: url), let host = c.host, !host.isEmpty else { return nil }
        return Endpoint(host: host, port: c.port ?? 80, user: c.user?.removingPercentEncoding, password: c.password?.removingPercentEncoding)
    }

    public func validate() throws {
        guard mode == .custom else { return }
        guard let url, let c = URLComponents(string: url), c.scheme?.lowercased() == "http", let h = c.host, !h.isEmpty else {
            throw ImageError.invalid("a custom proxy needs an http://host:port URL")
        }
        if let p = c.port, !(1...65535).contains(p) { throw ImageError.invalid("proxy port out of range") }
    }

    /// Settings safe to show: the password in the URL is replaced.
    public var redacted: ProxySettings {
        var r = self
        if let url, var c = URLComponents(string: url), c.password != nil { c.password = Self.redactedPassword; r.url = c.string }
        return r
    }

    /// A submitted `***` password means "keep the stored one".
    public func restoringPassword(from old: ProxySettings) -> ProxySettings {
        guard let url, var c = URLComponents(string: url), c.password == Self.redactedPassword else { return self }
        c.password = old.url.flatMap(URLComponents.init(string:))?.password
        var r = self; r.url = c.string
        return r
    }

    /// True when `host` should connect directly. Applies to the custom mode only.
    public func bypasses(_ host: String) -> Bool {
        let h = host.lowercased()
        for raw in exceptions {
            let e = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if e.isEmpty { continue }
            if e == "*" || e == h { return true }
            if e.hasPrefix("*.") || e.hasPrefix(".") {
                let suffix = e.hasPrefix("*.") ? String(e.dropFirst(1)) : e
                if h.hasSuffix(suffix) || h == String(suffix.dropFirst()) { return true }
            } else if h.hasSuffix("." + e) { return true }
            if e.contains("/"), Self.cidr(e, contains: h) { return true }
        }
        return false
    }

    static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p { guard let b = UInt8(x) else { return nil }; v = v << 8 | UInt32(b) }
        return v
    }

    static func cidr(_ range: String, contains host: String) -> Bool {
        let parts = range.split(separator: "/")
        guard parts.count == 2, let base = ipv4(String(parts[0])), let bits = Int(parts[1]), (0...32).contains(bits),
              let ip = ipv4(host) else { return false }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return ip & mask == base & mask
    }

    // MARK: persistence

    public static func load(from url: URL) -> ProxySettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ProxySettings.self, from: d) else { return ProxySettings() }
        return s
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        // Born 0600 so the password is never readable under the umask, then renamed over the old file.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
