import Foundation
import NoodleCore

extension Engine {
    struct Publication {
        var key: String
        var binding: PortBinding?
    }

    /// A single port, optionally with a host address and port. IPv6 addresses use brackets.
    static func publication(_ spec: String, removing: Bool) throws -> Publication {
        func invalid() -> EngineError { .invalid("invalid port specification: \(spec)") }
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw invalid() }
        let proto = parts.count == 2 ? String(parts[1]) : "tcp"
        guard proto == "tcp" || proto == "udp" else { throw invalid() }
        var text = String(parts[0])
        var address = ""
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]"), text[text.index(after: end)...].hasPrefix(":") else { throw invalid() }
            address = String(text[text.index(after: text.startIndex)..<end])
            text = String(text[text.index(end, offsetBy: 2)...])
        }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let host: String
        let target: String
        switch fields.count {
        case 1 where address.isEmpty:
            target = fields[0]; host = ""
        case 2:
            host = fields[0]; target = fields[1]
        case 3 where address.isEmpty:
            address = fields[0]; host = fields[1]; target = fields[2]
        default: throw invalid()
        }
        guard let port = Int(target), (1...65535).contains(port),
              host.isEmpty || (Int(host).map { (0...65535).contains($0) } ?? false) else { throw invalid() }
        if !address.isEmpty {
            var v4 = in_addr(), v6 = in6_addr()
            var normalized = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_pton(AF_INET, address, &v4) == 1 {
                guard inet_ntop(AF_INET, &v4, &normalized, socklen_t(INET6_ADDRSTRLEN)) != nil else { throw invalid() }
            } else if inet_pton(AF_INET6, address, &v6) == 1 {
                guard inet_ntop(AF_INET6, &v6, &normalized, socklen_t(INET6_ADDRSTRLEN)) != nil else { throw invalid() }
            } else { throw invalid() }
            address = String(decoding: normalized.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let binding = removing && fields.count == 1 ? nil : PortBinding(HostIp: address, HostPort: host.isEmpty ? "" : String(Int(host)!))
        return Publication(key: "\(port)/\(proto)", binding: binding)
    }
}
