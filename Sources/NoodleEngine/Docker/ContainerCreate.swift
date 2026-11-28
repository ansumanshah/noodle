import Foundation
import NoodleCore

public struct IPAMConfigEntry: Codable, Sendable, Equatable {
    public var IPv4Address: String?
    public var IPv6Address: String?
    public var LinkLocalIPs: [String]?
    public init() {}
}

public struct EndpointSettings: Codable, Sendable, Equatable {
    public var IPAMConfig: IPAMConfigEntry?
    public var Links: [String]?
    public var Aliases: [String]?
    public var MacAddress = ""
    public var NetworkID = ""
    public var EndpointID = ""
    public var Gateway = ""
    public var IPAddress = ""
    public var IPPrefixLen = 0
    public var IPv6Gateway = ""
    public var GlobalIPv6Address = ""
    public var GlobalIPv6PrefixLen = 0
    public var DriverOpts: [String: String]?
    public var DNSNames: [String]?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        IPAMConfig = c.opt(.IPAMConfig); Links = c.opt(.Links); Aliases = c.opt(.Aliases)
        MacAddress = c.get(.MacAddress, ""); NetworkID = c.get(.NetworkID, ""); EndpointID = c.get(.EndpointID, "")
        Gateway = c.get(.Gateway, ""); IPAddress = c.get(.IPAddress, ""); IPPrefixLen = c.get(.IPPrefixLen, 0)
        IPv6Gateway = c.get(.IPv6Gateway, ""); GlobalIPv6Address = c.get(.GlobalIPv6Address, ""); GlobalIPv6PrefixLen = c.get(.GlobalIPv6PrefixLen, 0)
        DriverOpts = c.opt(.DriverOpts); DNSNames = c.opt(.DNSNames)
    }
}

public struct NetworkingConfig: Codable, Sendable, Equatable {
    public var EndpointsConfig: [String: EndpointSettings]?
    public init() {}
}

/// Body of `POST /containers/create`: the container Config fields sit at the top level next to HostConfig.
public struct ContainerCreateRequest: Codable, Sendable, Equatable {
    public var config: ContainerConfig
    public var hostConfig: HostConfig
    public var networking: NetworkingConfig

    public init(config: ContainerConfig = .init(), hostConfig: HostConfig = .init(), networking: NetworkingConfig = .init()) {
        self.config = config; self.hostConfig = hostConfig; self.networking = networking
    }
    private enum K: String, CodingKey { case HostConfig, NetworkingConfig }
    public init(from d: Decoder) throws {
        config = try ContainerConfig(from: d)
        let c = try d.container(keyedBy: K.self)
        hostConfig = c.get(.HostConfig, HostConfig())
        networking = c.get(.NetworkingConfig, NetworkingConfig())
    }
    public func encode(to e: Encoder) throws {
        try config.encode(to: e)
        var c = e.container(keyedBy: K.self)
        try c.encode(hostConfig, forKey: .HostConfig)
        try c.encode(networking, forKey: .NetworkingConfig)
    }
}
