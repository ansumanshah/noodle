import Foundation
import NoodleCore

/// Legacy `--link`, and the embedded DNS server settings for a container.
/// Default bridge: /etc/hosts lines and environment variables, fixed at start.
/// User network: an alias the container's embedded resolver maps to the target, at lookup time.
extension Engine {
    static let embeddedResolver = "127.0.0.11"

    /// "target:alias", "target", or the stored "/target:/parent/alias".
    static func parseLink(_ link: String) -> (target: String, alias: String) {
        let parts = link.split(separator: ":", maxSplits: 1).map(String.init)
        let first = parts.first ?? link
        let target = first.hasPrefix("/") ? String(first.dropFirst()) : first
        guard parts.count == 2 else { return (target, target) }
        return (target, parts[1].split(separator: "/").last.map(String.init) ?? parts[1])
    }

    /// `net.*` sysctls belong to the container's network namespace, so they are safe to set.
    static func isNetSysctl(_ key: String, value: String) -> Bool {
        let keyChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let valueChars = keyChars.union(CharacterSet(charactersIn: " \t"))
        return key.hasPrefix("net.") && !key.contains("..") && !key.hasSuffix(".") && key.utf8.count <= 128 && !value.isEmpty
            && key.utf8.allSatisfy { $0 < 128 } && value.utf8.allSatisfy { $0 < 128 }
            && key.unicodeScalars.allSatisfy(keyChars.contains) && value.unicodeScalars.allSatisfy(valueChars.contains)
    }

    func applyLinks(_ hc: inout HostConfig, endpoints: inout [String: EndpointRecord], primary: String, name: String) throws {
        guard let links = hc.Links, !links.isEmpty else { return }
        if primary == "host" {
            throw EngineError.invalid("--link requires a container network namespace; network mode host shares the guest namespace")
        }
        if endpoints[primary] != nil, networks.values.first(where: { $0.name == primary })?.builtin == false {
            endpoints[primary]?.links += links
            hc.Links = nil
            return
        }
        hc.Links = try links.map { link in
            let (target, alias) = Self.parseLink(link)
            guard let id = try? resolveContainerID(target), let child = containers[id] else {
                throw EngineError.invalid("could not get container for \(target)")
            }
            guard child.isRunningLike else {
                throw EngineError.invalid("Cannot link to a non running container: /\(child.name) AS /\(name)/\(alias)")
            }
            return "/\(child.name):/\(name)/\(alias)"
        }
    }

    /// The default bridge containers this one links to, all of which must be running.
    func linkedContainers(_ c: ContainerRecord) throws -> [(target: ContainerRecord, alias: String)] {
        try (c.hostConfig.Links ?? []).map { link in
            let (name, alias) = Self.parseLink(link)
            guard let id = try? resolveContainerID(name), let target = containers[id] else {
                throw EngineError.invalid("could not get container for \(name)")
            }
            guard target.isRunningLike else {
                throw EngineError.invalid("Cannot link to a non running container: /\(target.name) AS /\(c.name)/\(alias)")
            }
            return (target, alias)
        }
    }

    static func linkAddress(_ target: ContainerRecord) -> String? {
        guard let e = target.endpoints[target.primaryNetwork] else { return nil }
        return e.ip.isEmpty ? e.ip6 : e.ip
    }

    static func linkHosts(_ links: [(target: ContainerRecord, alias: String)]) -> [String] {
        links.compactMap { link in
            guard let ip = linkAddress(link.target), !ip.isEmpty else { return nil }
            let names = link.alias == link.target.name ? [link.alias, link.target.shortID] : [link.alias, link.target.shortID, link.target.name]
            return "\(ip) \(names.joined(separator: " "))"
        }
    }

    /// The variables Docker gives a linked container: `<ALIAS>_NAME`, `_PORT*`, `_ENV_*`.
    static func linkEnv(_ links: [(target: ContainerRecord, alias: String)], of c: ContainerRecord) -> [String] {
        var env: [String] = []
        for (target, alias) in links {
            let prefix = alias.uppercased().replacingOccurrences(of: "-", with: "_")
            env.append("\(prefix)_NAME=/\(c.name)/\(alias)")
            let ip = linkAddress(target) ?? ""
            let ports = (target.config.ExposedPorts ?? [:]).keys.compactMap { key -> (port: Int, proto: String)? in
                PortSpec.parse(key).map { ($0.port, $0.proto) }
            }.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
            if let lowest = ports.first { env.append("\(prefix)_PORT=\(lowest.proto)://\(ip):\(lowest.port)") }
            for (port, proto) in ports {
                let key = "\(prefix)_PORT_\(port)_\(proto.uppercased())"
                env += ["\(key)=\(proto)://\(ip):\(port)", "\(key)_ADDR=\(ip)", "\(key)_PORT=\(port)", "\(key)_PROTO=\(proto)"]
            }
            for entry in target.config.Env ?? [] {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = entry[..<eq]
                if key == "HOME" || key == "PATH" || key == "HOSTNAME" { continue }
                env.append("\(prefix)_ENV_\(entry)")
            }
        }
        return env
    }

    /// Set when the container is on a user network: those use the embedded resolver.
    func guestResolver(for c: ContainerRecord) -> GuestResolver? {
        guard c.endpoints.values.contains(where: { networks[$0.networkID]?.builtin == false }) else { return nil }
        let links = c.endpoints.values.flatMap(\.links).map { link -> GuestResolver.Link in
            let (target, alias) = Self.parseLink(link)
            return GuestResolver.Link(alias: alias, target: target)
        }
        return GuestResolver(servers: c.hostConfig.Dns ?? [], links: links)
    }

    /// `--network container:x` with x on a user network shares x's namespace, so x's resolver answers.
    func sharesEmbeddedResolver(_ c: ContainerRecord) -> Bool {
        guard c.primaryNetwork.hasPrefix("container:"), let id = try? resolveContainerID(String(c.primaryNetwork.dropFirst(10))),
              let target = containers[id] else { return false }
        return guestResolver(for: target) != nil
    }
}

extension GuestResolver {
    var json: JSONValue {
        .object(["servers": .strings(servers),
                 "links": .array(links.map { .object(["alias": .string($0.alias), "target": .string($0.target)]) })])
    }
}
