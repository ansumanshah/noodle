import Foundation

/// Parses Docker port keys such as "80", "80/tcp" or "53/udp". Image configs come from untrusted
/// registries, so odd keys ("", "/", "/tcp", "x/tcp") return nil rather than being indexed blindly.
enum PortSpec {
    static func parse(_ key: String) -> (port: Int, proto: String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let port = Int(first), (1...65535).contains(port) else { return nil }
        let proto = parts.count > 1 && !parts[1].isEmpty ? parts[1] : "tcp"
        return (port, proto)
    }
}
