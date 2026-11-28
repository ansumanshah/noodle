import Foundation

/// A published port as a developer would type it: the address it is bound to, the protocol, and the scheme a
/// browser would need. One helper for the Overview and the menu bar, so neither invents an endpoint.
struct PortEndpoint: Hashable, Sendable, Identifiable {
    static func == (a: PortEndpoint, b: PortEndpoint) -> Bool { a.id == b.id && a.name?.host == b.name?.host }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(name?.host) }
    /// "localhost" for a wildcard binding, otherwise the address the daemon reports.
    let host: String
    let port: Int
    let privatePort: Int
    /// Lowercased: tcp, udp or sctp.
    let proto: String

    /// Private ports that speak TLS. Anything else is plain HTTP when it is offered to a browser at all.
    private static let tlsPorts: Set<Int> = [443, 8443]
    private static let wildcards: Set<String> = ["", "0.0.0.0", "::", "[::]"]

    /// The local name that serves this port (`web.localhost`), when the daemon has one: shown and opened in place of `host:port`.
    var name: (host: String, url: URL)?

    var id: String { "\(host)|\(port)|\(proto)" }
    var isTCP: Bool { proto == "tcp" }
    var scheme: String { Self.tlsPorts.contains(privatePort) ? "https" : "http" }
    /// `host:port`, with an IPv6 host in brackets.
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    /// Only a TCP endpoint can be opened in a browser.
    var url: URL? { isTCP ? (name?.url ?? URL(string: "\(scheme)://\(address)")) : nil }
    var shown: String { name?.host ?? address }

    init?(_ mapping: PortMapping) {
        guard let published = mapping.publicPort else { return nil }
        let bound = (mapping.ip ?? "").trimmingCharacters(in: .whitespaces)
        host = Self.wildcards.contains(bound) ? "localhost" : bound.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        port = published
        privatePort = mapping.privatePort
        proto = mapping.type.lowercased()
    }

    /// The endpoints a running container serves, once each (IPv4 and IPv6 wildcards collapse), lowest port first.
    /// The container's local name goes on its first web port; the rest keep their `host:port`.
    static func list(_ container: ContainerSummary, names: LocalNameTable = LocalNameTable()) -> [PortEndpoint] {
        guard container.state == "running" else { return [] }
        var seen = Set<String>()
        var list = container.ports.compactMap(PortEndpoint.init).filter { seen.insert($0.id).inserted }
            .sorted { ($0.port, $0.isTCP ? 0 : 1, $0.host) < ($1.port, $1.isTCP ? 0 : 1, $1.host) }
        if let link = names.link(for: container), let i = list.firstIndex(where: { PortKind.of($0, image: container.image) == .web }) {
            list[i].name = link
        }
        return list
    }
}
