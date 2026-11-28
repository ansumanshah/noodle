import Darwin
import Foundation

struct ModelBinding {
    static let defaultPort = 11345
    let host: String
    let port: Int

    init(arguments: ArraySlice<String>) throws {
        let options = Array(arguments)
        guard options.count.isMultiple(of: 2) else {
            throw CLIError.usage("serve options need a value. See 'noodle model help'.")
        }
        var address: String?
        var selectedPort: Int?
        for index in stride(from: 0, to: options.count, by: 2) {
            let value = options[index + 1]
            switch options[index] {
            case "--port" where selectedPort == nil:
                guard let port = Int(value), (1024...65535).contains(port) else {
                    throw CLIError.usage("use a port between 1024 and 65535")
                }
                selectedPort = port
            case "--workloads" where address == nil:
                try Self.requireVMBridge(value)
                address = value
            default:
                throw CLIError.usage("unknown or repeated serve option \(options[index])")
            }
        }
        host = address ?? "127.0.0.1"
        port = selectedPort ?? Self.defaultPort
    }

    static func requireVMBridge(_ address: String) throws {
        let message = "workload access needs a private IPv4 address assigned to an active VM bridge (bridge100 or above)"
        let invalid = CLIError(message)
        var requested = in_addr()
        guard inet_pton(AF_INET, address, &requested) == 1 else { throw CLIError.usage(message) }
        let value = UInt32(bigEndian: requested.s_addr)
        let isPrivate = value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8
        guard isPrivate else { throw CLIError.usage(message) }

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { throw modelPOSIXError() }
        defer { freeifaddrs(interfaces) }
        for item in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0, let socket = interface.ifa_addr,
                  socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("bridge"), let number = Int(name.dropFirst("bridge".count)), number >= 100 else { continue }
            let actual = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if actual.s_addr == requested.s_addr { return }
        }
        throw invalid
    }
}
