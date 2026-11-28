import Foundation
import NoodleCore

/// Names for processes already running on this Mac. The daemon holds the name and port; it never starts the process.
extension LocalNames {
    /// The label(s) before `.localhost` / `.noodle.local`. Dots are allowed (`api.myapp`); case is not folded.
    public static func validHostLabel(_ name: String) -> Bool {
        name == name.lowercased() && name != suffix && name != brandedSuffix && LocalNameDomain.isSupported(name + "." + suffix)
            && !name.hasSuffix("." + suffix) && !name.hasSuffix("." + brandedSuffix)
            && LocalNameDomain.isSupported(name + "." + brandedSuffix)
    }

    public static func hostNames(_ name: String) -> [String] { ["\(name).\(suffix)", "\(name).\(brandedSuffix)"] }

    /// The first host of a host route that a running container already answers to, or nil. The container wins.
    public static func clash(_ name: String, with table: [Target]) -> String? {
        let mine = Set(hostNames(name))
        return table.first { $0.kind == "container" && mine.contains($0.host) }?.host
    }
}

extension NameRouter {
    /// True when Accept ranks text/html (or xhtml) above everything else. Absent or `*/*` means a script, so JSON.
    static func prefersHTML(_ accept: String?) -> Bool {
        var best: (q: Double, html: Bool)?
        for part in (accept ?? "").split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let type = fields.first, !type.isEmpty else { continue }
            let q = fields.dropFirst().compactMap { $0.hasPrefix("q=") ? Double($0.dropFirst(2)) : nil }.first ?? 1
            guard q > 0 else { continue }
            if best == nil || q > best!.q { best = (q, type == "text/html" || type == "application/xhtml+xml") }
        }
        return best?.html ?? false
    }

    struct RequestHead {
        var host = "", accept: String?, hop = false
        init(_ text: String) {
            for line in text.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch line[..<colon].lowercased() {
                case "host": host = LocalNames.hostOnly(value)
                case "accept": accept = value
                case "noodle-hop": hop = true
                default: break
                }
            }
        }
    }

    /// Mark a proxied request so a route that points back at the router is refused instead of looping.
    static func markHop(_ head: Data) -> Data {
        guard let eol = head.range(of: Data("\r\n".utf8)) else { return head }
        return head[..<eol.upperBound] + Data("Noodle-Hop: 1\r\n".utf8) + head[eol.upperBound...]
    }

    static func jsonBody(error: String, name: String, hint: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": error, "name": name, "hint": hint], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension Engine {
    func loadHostRoutes() {
        guard let data = try? Data(contentsOf: paths.hostNamesFile),
              let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        hostRoutes = saved.filter { LocalNames.validHostLabel($0.key) && (1...65535).contains($0.value) }
    }

    private func saveHostRoutes() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(hostRoutes).write(to: paths.hostNamesFile, options: .atomic)
    }

    /// Host routes whose hosts are not already taken (a container, or a dev lease, wins).
    func hostTargets(excluding taken: Set<String>) -> [LocalNames.Target] {
        hostRoutes.sorted { $0.key < $1.key }.flatMap { name, port in
            LocalNames.hostNames(name).filter { !taken.contains($0) }.map {
                LocalNames.Target(host: $0, containerID: "host:" + name, ip: "127.0.0.1", port: port, kind: "host")
            }
        }
    }

    public func addHostName(_ name: String, port: Int) async throws -> [LocalNames.Target] {
        guard Self.namesEnabled else { throw EngineError.unavailable("Local names are off (NOODLE_LOCAL_NAMES=0).") }
        guard LocalNames.validHostLabel(name), (1...65535).contains(port) else {
            throw EngineError.badRequest("Expected a lowercase DNS name (letters, digits, hyphens, dots; labels up to 63 characters) and a port from 1 to 65535.")
        }
        refreshNames()
        if let host = LocalNames.clash(name, with: nameTable) {
            throw EngineError.conflict("\(host) already belongs to a running container, and a container name always wins. Choose another name.")
        }
        if nameTable.contains(where: { $0.containerID.hasPrefix("dev:") && LocalNames.hostNames(name).contains($0.host) }) {
            throw EngineError.conflict("\(name) is already used by a noodle dev route. Choose another name.")
        }
        let previous = hostRoutes[name]
        hostRoutes[name] = port
        do {
            try saveHostRoutes()
            refreshNames()
            guard let router = nameRouter else { throw EngineError.unavailable(namesError ?? "Local names could not start.") }
            for host in LocalNames.hostNames(name) { try await router.identities.prepare(host: host) }
            try await router.dns.waitUntilRegistered(name + "." + LocalNames.brandedSuffix)
        } catch {
            hostRoutes[name] = previous
            try? saveHostRoutes()
            refreshNames()
            throw error
        }
        return nameTable.filter { $0.containerID == "host:" + name }
    }

    public func removeHostName(_ name: String) throws {
        guard hostRoutes.removeValue(forKey: name) != nil else { throw EngineError.notFound("No host name \(name).") }
        try saveHostRoutes()
        refreshNames()
    }
}
