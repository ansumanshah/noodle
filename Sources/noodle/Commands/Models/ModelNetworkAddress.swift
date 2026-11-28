import Darwin
import Foundation
import SystemConfiguration

/// Where other devices reach this Mac: the Bonjour name, plus the Wi-Fi or Ethernet IPv4 as a fallback.
enum ModelNetworkAddress {
    struct Report: Encodable { let enabled: Bool; let url: String?; let ipURL: String? }

    static func current(port: Int) -> (name: String, ip: String?)? {
        guard let host = SCDynamicStoreCopyLocalHostName(nil) as String? else {
            return lanIPv4().map { ("http://\($0):\(port)/v1", nil) }
        }
        return ("http://\(host).local:\(port)/v1", lanIPv4().map { "http://\($0):\(port)/v1" })
    }

    /// First IPv4 on an en* interface that is up and not link-local.
    static func lanIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for item in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let i = item.pointee
            guard i.ifa_flags & UInt32(IFF_UP) != 0, let socket = i.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  String(cString: i.ifa_name).hasPrefix("en") else { continue }
            var address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let value = String(cString: text)
            if !value.hasPrefix("169.254.") { return value }
        }
        return nil
    }
}
