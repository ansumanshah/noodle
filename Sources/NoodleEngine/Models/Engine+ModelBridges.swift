import Darwin
import Foundation

extension Engine {
    public func setModelBridgeObserver(_ observer: (@Sendable (Bool) async -> Void)?) {
        modelBridgeObserver = observer
    }

    public nonisolated static func modelBridgeAddresses() async -> [String] {
        (try? await DockerModelRunner.disk {
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaces) == 0, let interfaces else { return [] }
            defer { freeifaddrs(interfaces) }
            var result: [String] = []
            for item in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
                let value = item.pointee
                guard value.ifa_flags & UInt32(IFF_UP) != 0, let address = value.ifa_addr,
                      address.pointee.sa_family == UInt8(AF_INET), strncmp(value.ifa_name, "bridge", 6) == 0,
                      isdigit(Int32(value.ifa_name[6])) != 0, atoi(value.ifa_name + 6) >= 100 else { continue }
                var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil {
                    result.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
            }
            return Array(Set(result)).sorted()
        }) ?? []
    }
}
