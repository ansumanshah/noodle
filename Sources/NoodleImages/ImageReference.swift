import Foundation

/// A parsed image reference with Docker's normalisation rules:
/// `ubuntu` -> `docker.io/library/ubuntu:latest`, `user/app:1` -> `docker.io/user/app:1`,
/// `ghcr.io/o/r@sha256:..` keeps its domain and digest.
public struct ImageReference: Sendable, Hashable, CustomStringConvertible {
    public static let hubDomain = "docker.io"
    public static let hubRegistryHost = "registry-1.docker.io"

    public var domain: String         // "docker.io", "ghcr.io", "localhost:5000"
    public var path: String           // "library/ubuntu"
    public var tag: String?           // nil when only a digest is given
    public var digest: String?

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty, invalid(String)
        public var description: String {
            switch self {
            case .empty: return "invalid reference format"
            case .invalid(let s): return "invalid reference format: \(s)"
            }
        }
    }

    public init(domain: String, path: String, tag: String?, digest: String?) {
        self.domain = domain; self.path = path; self.tag = tag; self.digest = digest
    }

    public static func parse(_ raw: String) throws -> ImageReference {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw ParseError.empty }
        guard s == s.lowercased() || s.contains("/") else { throw ParseError.invalid("repository name must be lowercase") }

        var digest: String?
        if let at = s.firstIndex(of: "@") {
            digest = String(s[s.index(after: at)...])
            s = String(s[..<at])
            guard let d = digest, isDigestSyntax(d) else { throw ParseError.invalid("bad digest") }
        }

        // split off tag: last ':' after the last '/'
        var tag: String?
        let lastSlash = s.lastIndex(of: "/")
        if let colon = s.lastIndex(of: ":"), lastSlash == nil || colon > lastSlash! {
            tag = String(s[s.index(after: colon)...])
            s = String(s[..<colon])
            guard let t = tag, isTagSyntax(t) else { throw ParseError.invalid("bad tag") }
        }

        var domain = hubDomain
        var path = s
        if let slash = s.firstIndex(of: "/") {
            let first = String(s[..<slash])
            if first.contains(".") || first.contains(":") || first == "localhost" {
                domain = first
                path = String(s[s.index(after: slash)...])
            }
        }
        if domain == "index.docker.io" || domain == "registry-1.docker.io" { domain = hubDomain }
        if domain == hubDomain, !path.contains("/") { path = "library/" + path }
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ isPathComponent(String($0)) }) else {
            throw ParseError.invalid(raw)
        }
        if tag == nil && digest == nil { tag = "latest" }
        return ImageReference(domain: domain, path: path, tag: tag, digest: digest)
    }

    static func isTagSyntax(_ t: String) -> Bool {
        guard !t.isEmpty, t.count <= 128, let f = t.unicodeScalars.first else { return false }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard word.contains(f), f.isASCII else { return false }
        return t.unicodeScalars.allSatisfy { $0.isASCII && (word.contains($0) || $0 == "." || $0 == "-") }
    }

    static func isDigestSyntax(_ d: String) -> Bool {
        guard let c = d.firstIndex(of: ":") else { return false }
        let algo = d[..<c], hex = d[d.index(after: c)...]
        return !algo.isEmpty && hex.count >= 32 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isPathComponent(_ c: String) -> Bool {
        guard !c.isEmpty else { return false }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard c.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return false }
        return c.first!.isLetter || c.first!.isNumber
    }

    /// Host used for HTTP requests.
    public var registryHost: String { domain == Self.hubDomain ? Self.hubRegistryHost : domain }
    public var isLocalHTTPAllowed: Bool {
        let h = domain.split(separator: ":").first.map(String.init) ?? domain
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".localhost")
    }

    /// `repo` without domain: `library/ubuntu`
    public var repository: String { path }

    /// What the user would type: `ubuntu`, `user/app`, `ghcr.io/o/r`.
    public var familiarName: String {
        if domain == Self.hubDomain { return path.hasPrefix("library/") && path.dropFirst(8).contains("/") == false ? String(path.dropFirst(8)) : path }
        return domain + "/" + path
    }
    /// `ubuntu:latest` (Docker's `RepoTags` form).
    public var familiar: String {
        var s = familiarName
        if let tag { s += ":" + tag }
        if let digest, tag == nil { s += "@" + digest }
        return s
    }
    /// Fully qualified name without tag: `docker.io/library/ubuntu`.
    public var name: String { domain + "/" + path }
    public var reference: String { digest ?? tag ?? "latest" }
    public var description: String {
        var s = name
        if let tag { s += ":" + tag }
        if let digest { s += "@" + digest }
        return s
    }
    public func withTag(_ t: String) -> ImageReference { var r = self; r.tag = t; r.digest = nil; return r }
}

public struct Platform: Sendable, Hashable, Codable, CustomStringConvertible {
    public var os: String
    public var architecture: String
    public var variant: String?

    public init(os: String = "linux", architecture: String, variant: String? = nil) {
        self.os = os; self.architecture = architecture; self.variant = variant
    }

    public static let arm64 = Platform(architecture: "arm64", variant: "v8")
    public static let amd64 = Platform(architecture: "amd64")

    /// Parse `linux/amd64`, `amd64`, `linux/arm64/v8`, `arm64v8`.
    public static func parse(_ s: String) -> Platform? {
        let parts = s.lowercased().split(separator: "/").map(String.init)
        func arch(_ a: String) -> (String, String?) {
            switch a {
            case "x86_64", "x86-64", "amd64": return ("amd64", nil)
            case "aarch64", "arm64": return ("arm64", "v8")
            case "i386", "386": return ("386", nil)
            default: return (a, nil)
            }
        }
        switch parts.count {
        case 1:
            let (a, v) = arch(parts[0]); return Platform(architecture: a, variant: v)
        case 2:
            let (a, v) = arch(parts[1]); return Platform(os: parts[0], architecture: a, variant: v)
        case 3:
            let (a, _) = arch(parts[1]); return Platform(os: parts[0], architecture: a, variant: parts[2])
        default: return nil
        }
    }

    public func matches(os o: String?, architecture a: String?, variant v: String?) -> Bool {
        guard o == os, a == architecture else { return false }
        // arm64 manifests often omit the variant or say v8
        if let want = variant, let have = v, !have.isEmpty { return want == have }
        return true
    }
    public var description: String { "\(os)/\(architecture)" + (variant.map { "/\($0)" } ?? "") }
}
