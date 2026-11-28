import Foundation
import NoodleCore
import NoodleImages

// MARK: - List / inspect

extension Engine {
    func stateJSON(_ c: ContainerRecord) -> ContainerState {
        var s = ContainerState()
        s.Status = c.status.rawValue
        s.Running = c.isRunningLike
        s.Paused = c.status == .paused
        s.Restarting = c.status == .restarting
        s.OOMKilled = c.oomKilled
        s.Dead = c.status == .dead
        s.Pid = c.pid
        s.ExitCode = c.exitCode
        s.Error = c.error
        if let st = c.startedAt { s.StartedAt = ISO8601.string(st) }
        if let f = c.finishedAt { s.FinishedAt = ISO8601.string(f) }
        s.Health = c.health
        return s
    }

    func commandString(_ c: ContainerRecord) -> String {
        ((c.config.Entrypoint ?? []) + (c.config.Cmd ?? [])).joined(separator: " ")
    }

    func statusText(_ c: ContainerRecord) -> String {
        switch c.status {
        case .created: return "Created"
        case .running:
            let health = c.health.map { $0.Status == "starting" ? " (health: starting)" : " (\($0.Status))" } ?? ""
            return "Up \(Self.humanDuration(Date().timeIntervalSince(c.startedAt ?? Date())))\(health)"
        case .paused: return "Up \(Self.humanDuration(Date().timeIntervalSince(c.startedAt ?? Date()))) (Paused)"
        case .restarting: return "Restarting (\(c.exitCode)) \(Self.humanDuration(Date().timeIntervalSince(c.finishedAt ?? Date()))) ago"
        case .removing: return "Removal In Progress"
        case .dead: return "Dead"
        case .exited:
            guard let f = c.finishedAt else { return "Exited (\(c.exitCode))" }
            return "Exited (\(c.exitCode)) \(Self.humanDuration(Date().timeIntervalSince(f))) ago"
        }
    }

    static func humanDuration(_ s: TimeInterval) -> String {
        let sec = Int(max(0, s))
        if sec < 1 { return "Less than a second" }
        if sec == 1 { return "1 second" }
        if sec < 60 { return "\(sec) seconds" }
        let min = sec / 60
        if min == 1 { return "About a minute" }
        if min < 60 { return "\(min) minutes" }
        let h = min / 60
        if h == 1 { return "About an hour" }
        if h < 48 { return "\(h) hours" }
        let d = h / 24
        if d < 14 { return "\(d) days" }
        if d < 60 { return "\(d / 7) weeks" }
        if d < 730 { return "\(d / 30) months" }
        return "\(d / 365) years"
    }

    func ports(_ c: ContainerRecord) -> [PortSummary] {
        var out: [PortSummary] = []
        for (key, binds) in c.ports.sorted(by: { $0.key < $1.key }) {
            guard let spec = PortSpec.parse(key) else { continue }
            for b in binds { out.append(PortSummary(IP: b.HostIp.isEmpty ? "0.0.0.0" : b.HostIp, PrivatePort: spec.port, PublicPort: Int(b.HostPort), Type: spec.proto)) }
        }
        for key in (c.config.ExposedPorts ?? [:]).keys.sorted() where c.ports[key] == nil {
            guard let spec = PortSpec.parse(key) else { continue }
            out.append(PortSummary(IP: nil, PrivatePort: spec.port, PublicPort: nil, Type: spec.proto))
        }
        return out
    }

    func endpointJSON(_ e: EndpointRecord, network n: NetworkRecord?, container c: ContainerRecord) -> EndpointSettings {
        var s = EndpointSettings()
        s.NetworkID = e.networkID; s.EndpointID = c.isRunningLike ? e.endpointID : ""
        s.Gateway = c.isRunningLike ? (n?.gateway ?? "") : ""
        if let ip6 = e.ip6 {
            s.GlobalIPv6Address = ip6
            s.GlobalIPv6PrefixLen = n?.subnet6.flatMap { IPv6Net(cidr: $0) }?.prefix ?? 64
            s.IPv6Gateway = c.isRunningLike ? (n?.gateway6 ?? "") : ""
        }
        s.IPAddress = e.ip; s.MacAddress = e.mac
        s.IPPrefixLen = e.ip.isEmpty ? 0 : (n.flatMap { IPv4Net(cidr: $0.subnet)?.prefix } ?? 16)
        s.Aliases = e.aliases.isEmpty && c.isRunningLike ? [c.shortID] : (e.aliases + (c.isRunningLike ? [c.shortID] : []))
        s.Links = e.links.isEmpty ? nil : e.links
        if e.staticIP != nil || e.staticIP6 != nil {
            var ic = IPAMConfigEntry(); ic.IPv4Address = e.staticIP; ic.IPv6Address = e.staticIP6
            s.IPAMConfig = ic
        }
        s.DNSNames = c.isRunningLike ? [c.name, c.shortID] + e.aliases : nil
        return s
    }

    func summary(_ c: ContainerRecord) -> ContainerSummary {
        var s = ContainerSummary()
        s.Id = c.id; s.Names = ["/" + c.name]; s.Image = c.image; s.ImageID = c.imageID
        s.Command = commandString(c); s.Created = Int64(c.created.timeIntervalSince1970)
        s.Ports = ports(c); s.Labels = c.config.Labels ?? [:]
        s.State = c.status.rawValue; s.Status = statusText(c)
        s.HostConfig.NetworkMode = c.hostConfig.NetworkMode
        for (name, e) in c.endpoints { s.NetworkSettings.Networks[name] = endpointJSON(e, network: networks.values.first { $0.name == name }, container: c) }
        s.Mounts = c.mounts
        return s
    }

    public func listContainers(all: Bool = false, limit: Int? = nil, filters: Filters = Filters()) -> [ContainerSummary] {
        var list = containers.values.sorted { $0.created > $1.created }
        if !all && filters["status"].isEmpty { list = list.filter { $0.status == .running || $0.status == .restarting || $0.status == .paused } }
        for f in ["id", "name", "status", "label", "exited", "ancestor", "before", "since", "network", "volume", "expose", "publish", "health"] where filters.has(f) || f == "label" {
            switch f {
            case "id": list = list.filter { c in filters["id"].contains { c.id.hasPrefix($0) } }
            case "name": list = list.filter { filters.nameMatches($0.name) }
            case "health": list = list.filter { c in filters["health"].contains(c.health?.Status ?? "none") }
            case "status": list = list.filter { filters["status"].contains($0.status.rawValue) }
            case "label": list = list.filter { filters.matchLabels($0.config.Labels ?? [:]) }
            case "exited": list = list.filter { $0.status == .exited && filters["exited"].contains(String($0.exitCode)) }
            case "ancestor":
                list = list.filter { c in filters["ancestor"].contains { a in c.image == a || c.imageID == a || c.imageID.hasPrefix("sha256:" + a) || c.image.hasPrefix(a + ":") } }
            case "before":
                if let ref = try? resolveContainerID(filters["before"][0]), let r = containers[ref] { list = list.filter { $0.created < r.created } }
            case "since":
                if let ref = try? resolveContainerID(filters["since"][0]), let r = containers[ref] { list = list.filter { $0.created > r.created } }
            case "network": list = list.filter { c in filters["network"].contains { n in c.endpoints.keys.contains(n) || c.endpoints.values.contains { $0.networkID.hasPrefix(n) } } }
            case "volume": list = list.filter { c in filters["volume"].contains { v in c.mounts.contains { $0.Name == v || $0.Destination == v } } }
            case "expose": list = list.filter { c in filters["expose"].contains { e in (c.config.ExposedPorts ?? [:]).keys.contains { $0 == e || $0.hasPrefix(e + "/") } } }
            case "publish": list = list.filter { c in filters["publish"].contains { p in c.ports.keys.contains { $0 == p || $0.hasPrefix(p + "/") } } }
            default: break
            }
        }
        if let limit, limit > 0 { list = Array(list.prefix(limit)) }
        return list.map { summary($0) }
    }

    public func containerUsesTTY(_ ref: String) throws -> Bool {
        let id = try resolveContainerID(ref)
        return containers[id]?.config.Tty ?? false
    }

    public func inspectContainer(_ ref: String) throws -> ContainerInspect {
        let id = try resolveContainerID(ref)
        return inspect(containers[id]!)
    }

    func inspect(_ c: ContainerRecord) -> ContainerInspect {
        var i = ContainerInspect()
        i.Id = c.id; i.Created = ISO8601.string(c.created)
        let argv = (c.config.Entrypoint ?? []) + (c.config.Cmd ?? [])
        i.Path = argv.first ?? ""; i.Args = Array(argv.dropFirst())
        i.State = stateJSON(c); i.Image = c.imageID
        let base = "/var/lib/docker/containers/\(c.id)"
        i.ResolvConfPath = base + "/resolv.conf"; i.HostnamePath = base + "/hostname"; i.HostsPath = base + "/hosts"
        i.LogPath = base + "/\(c.id)-json.log"
        i.Name = "/" + c.name; i.RestartCount = c.restartCount
        i.ExecIDs = c.execIDs.isEmpty ? nil : c.execIDs
        i.HostConfig = c.hostConfig; i.Mounts = c.mounts; i.Config = c.config; i.Config.Image = c.image
        var ns = NetworkSettings()
        ns.SandboxID = c.isRunningLike ? String(c.id.reversed().prefix(64)) : ""
        ns.SandboxKey = c.isRunningLike ? "/var/run/docker/netns/\(c.id.prefix(12))" : ""
        for key in (c.config.ExposedPorts ?? [:]).keys where c.ports[key] == nil && c.isRunningLike { ns.Ports[key] = .some(nil) }
        for (k, v) in c.ports { ns.Ports[k] = .some(v) }
        for (name, e) in c.endpoints {
            let n = networks.values.first { $0.name == name }
            ns.Networks[name] = endpointJSON(e, network: n, container: c)
        }
        if let p = ns.Networks[c.primaryNetwork] ?? ns.Networks.values.first {
            ns.EndpointID = p.EndpointID; ns.Gateway = p.Gateway; ns.IPAddress = p.IPAddress
            ns.IPPrefixLen = p.IPPrefixLen; ns.MacAddress = p.MacAddress
            ns.GlobalIPv6Address = p.GlobalIPv6Address; ns.GlobalIPv6PrefixLen = p.GlobalIPv6PrefixLen; ns.IPv6Gateway = p.IPv6Gateway
        }
        if ns.Networks.isEmpty, ["host", "none"].contains(c.primaryNetwork) || c.primaryNetwork.hasPrefix("container:") {
            ns.Networks[c.primaryNetwork] = EndpointSettings()
        }
        i.NetworkSettings = ns
        return i
    }
}
