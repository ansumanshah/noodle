import Foundation
import NoodleCore

/// Pure rules for local names: which local hosts a running container answers to, and who wins a collision.
/// Names are a function of the running set, so stop, restart, removal and port changes need no bookkeeping.
public enum LocalNames {
    public static let suffix = "localhost"
    public static let brandedSuffix = LocalNameDomain.brandedSuffix
    public static let domainLabel = "app.noodle.domain"
    public static let portLabel = "app.noodle.http.port"
    static let composeProject = "com.docker.compose.project"
    static let composeService = "com.docker.compose.service"
    // OfficialImagePorts records the image survey used for automatic HTTP destinations.

    /// What the table needs to know about one running container.
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var name: String
        public var labels: [String: String]
        public var ip: String
        public var published: [Int]      // container-side ports of -p / -P
        public var exposed: [Int]        // EXPOSE and --expose
        public var startedAt: Date

        public init(id: String, name: String, labels: [String: String] = [:], ip: String, published: [Int] = [], exposed: [Int] = [], startedAt: Date) {
            self.id = id; self.name = name; self.labels = labels; self.ip = ip
            self.published = published; self.exposed = exposed; self.startedAt = startedAt
        }
    }

    public struct Target: Sendable, Equatable, Codable {
        public var host: String
        public var containerID: String
        public var ip: String
        public var port: Int
        /// "container" or "host" (a process on this Mac, added with `noodle names add`).
        public var kind: String = "container"
    }

    /// One DNS label: lowercase letters, digits and inner hyphens. Empty when nothing usable remains.
    public static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if !out.isEmpty && out.last != "-" { out.append("-") }
        }
        while out.last == "-" { out.removeLast() }
        return String(out.prefix(63))
    }

    /// Bare names retain the historical `.localhost` default; explicit branded names stay branded.
    public static func customHost(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let host = t.hasSuffix("." + suffix) || t.hasSuffix("." + brandedSuffix) ? t : t + "." + suffix
        guard LocalNameDomain.isSupported(host) else { return nil }
        return host
    }

    /// The container-side port a request should reach, or nil when the container offers none.
    public static func webPort(_ c: Candidate) -> Int? {
        if let p = c.labels[portLabel].flatMap({ Int($0) }), (1...65535).contains(p) { return p }
        var candidates = c.published
        if candidates.isEmpty { candidates = c.exposed }
        let plain = candidates.filter { !tlsOnlyPorts.contains($0) }
        if !plain.isEmpty { candidates = plain }

        // Resolve each fallback separately. Numeric minima make input order irrelevant.
        var web: Int?
        var webRank = Int.max
        var unknown: Int?
        var other: Int?
        for port in candidates {
            guard let entry = OfficialImagePorts.table[port] else {
                unknown = min(unknown ?? port, port)
                continue
            }
            if entry.kind == .web {
                if entry.rank < webRank || (entry.rank == webRank && port < (web ?? Int.max)) {
                    web = port
                    webRank = entry.rank
                }
            } else {
                other = min(other ?? port, port)
            }
        }
        return web ?? unknown ?? other
    }

    /// Ports conventionally serving TLS only. Skipped by automatic selection when a plaintext port exists;
    /// the `app.noodle.http.port` label still overrides.
    static let tlsOnlyPorts: Set<Int> = [443, 2376, 4443, 8443, 9443]

    /// Hosts a container asks for, in preference order, before collisions are settled.
    static func wanted(_ c: Candidate) -> [String] {
        var hosts: [String] = []
        for raw in (c.labels[domainLabel] ?? "").split(separator: ",") { if let h = customHost(String(raw)) { hosts.append(h) } }
        if let project = c.labels[composeProject].map(sanitize), let service = c.labels[composeService].map(sanitize),
           !project.isEmpty, !service.isEmpty {
            hosts.append("\(service).\(project).\(suffix)")
        }
        let own = sanitize(c.name)
        if !own.isEmpty { hosts.append("\(own).\(suffix)") }
        return hosts + hosts.compactMap { host in
            guard host.hasSuffix("." + suffix) else { return nil }
            let branded = String(host.dropLast(suffix.count)) + brandedSuffix
            return LocalNameDomain.isSupported(branded) ? branded : nil
        }
    }

    /// Settle every host. The longest-running claimant keeps a contested name (ties by id); each other container
    /// gets the name with its short id added (`web-1a2b3c.localhost`), so nothing is ever unreachable.
    /// A Compose project name (`shop.localhost`) goes to the first service, by name, that has a web port.
    public static func table(_ all: [Candidate]) -> [Target] {
        let ordered = all.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        var owner: [String: String] = [:]
        var targets: [String: Target] = [:]
        func claim(_ host: String, _ c: Candidate, _ port: Int) {
            owner[host] = c.id
            targets[host] = Target(host: host, containerID: c.id, ip: c.ip, port: port)
        }
        for c in ordered {
            guard !c.ip.isEmpty, let port = webPort(c) else { continue }
            for host in wanted(c) {
                if owner[host] == nil || owner[host] == c.id { claim(host, c, port); continue }
                // The generated alias is a claim like any other: if someone already holds it, lengthen the id
                // part, and finally add a counter, until a free name turns up.
                let parts = host.split(separator: ".", maxSplits: 1).map(String.init)
                func alias(_ suffix: String) -> String { ([parts[0] + "-" + suffix] + parts.dropFirst()).joined(separator: ".") }
                var choice = alias(String(c.id.prefix(6)))
                if owner[choice] != nil && owner[choice] != c.id { choice = alias(String(c.id.prefix(12))) }
                var n = 2
                while owner[choice] != nil && owner[choice] != c.id { choice = alias("\(c.id.prefix(12))-\(n)"); n += 1 }
                claim(choice, c, port)
            }
        }
        var projects: [String: Candidate] = [:]
        for c in ordered where !c.ip.isEmpty && webPort(c) != nil {
            guard let project = c.labels[composeProject].map(sanitize), !project.isEmpty else { continue }
            let service = c.labels[composeService] ?? c.name
            if let cur = projects[project], (cur.labels[composeService] ?? cur.name) <= service { continue }
            projects[project] = c
        }
        for (project, c) in projects {
            for domain in [suffix, brandedSuffix] {
                let host = "\(project).\(domain)"
                if owner[host] == nil, let port = webPort(c) { claim(host, c, port) }
            }
        }
        return targets.values.sorted { $0.host < $1.host }
    }

    /// The Host header without its port, lowercased. Brackets and trailing dots are dropped.
    public static func hostOnly(_ header: String) -> String {
        var h = header.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("[") { return "" }
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
