import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    func bindPorts(_ c: inout ContainerRecord, endpoint: EndpointRecord?, in rt: GuestRuntime) throws {
        var wanted: [(key: String, binding: PortBinding)] = []
        for (key, binds) in c.hostConfig.PortBindings ?? [:] {
            for b in binds ?? [] { wanted.append((key, b)) }
        }
        if c.hostConfig.PublishAllPorts {
            for key in (c.config.ExposedPorts ?? [:]).keys where !(c.hostConfig.PortBindings ?? [:]).keys.contains(key) {
                wanted.append((key, PortBinding(HostIp: "", HostPort: "")))
            }
        }
        guard !wanted.isEmpty else { return }
        guard let endpoint, !endpoint.ip.isEmpty || endpoint.ip6 != nil else {
            if c.primaryNetwork == "host" || c.primaryNetwork == "none" { return }
            throw EngineError.internalError("cannot publish ports without a container address")
        }
        var created: [PortListener] = []
        c.ports = [:]
        let guestRef = rt.guest
        let opener: PortListener.Opener = { op, ip, port in
            try await guestRef.openStream(op, ["ip": .string(ip), "port": .int(Int64(port))])
        }
        do {
            for (key, b) in wanted {
                guard let spec = PortSpec.parse(key) else { throw EngineError.invalid("invalid port specification: \"\(key)\"") }
                let cport = spec.port, proto = spec.proto
                guard proto == "tcp" || proto == "udp" else { continue }
                let hostPort = Int(b.HostPort.split(separator: "-").first.map(String.init) ?? "") ?? 0
                let bound = try PortListener.publish(proto: proto, hostIP: b.HostIp, hostPort: hostPort, endpoint: endpoint, containerPort: cport, opener: opener) { created.append($0) }
                for l in bound { c.ports[key, default: []].append(PortBinding(HostIp: l.hostIP, HostPort: String(l.hostPort))) }
            }
        } catch {
            for l in created { l.stop() }
            c.ports = [:]
            throw error
        }
        listeners[c.id] = created
    }
}
