import Foundation
import NoodleCore

public struct HealthState: Codable, Sendable, Equatable {
    public struct LogEntry: Codable, Sendable, Equatable {
        public var Start: String
        public var End: String
        public var ExitCode: Int
        public var Output: String
    }
    public var Status = "starting"
    public var FailingStreak = 0
    public var Log: [LogEntry] = []
    public init() {}
}

public struct ContainerState: Codable, Sendable, Equatable {
    public var Status = "created"
    public var Running = false
    public var Paused = false
    public var Restarting = false
    public var OOMKilled = false
    public var Dead = false
    public var Pid = 0
    public var ExitCode = 0
    public var Error = ""
    public var StartedAt = "0001-01-01T00:00:00Z"
    public var FinishedAt = "0001-01-01T00:00:00Z"
    public var Health: HealthState?
    public init() {}
}

public struct MountPoint: Codable, Sendable, Equatable {
    public var `Type` = "volume"
    public var Name: String?
    public var Source = ""
    public var Destination = ""
    public var Driver: String?
    public var Mode = ""
    public var RW = true
    public var Propagation = ""
    public init() {}
}

public struct NetworkSettings: Codable, Sendable, Equatable {
    public var Bridge = ""
    public var SandboxID = ""
    public var SandboxKey = ""
    public var HairpinMode = false
    public var LinkLocalIPv6Address = ""
    public var LinkLocalIPv6PrefixLen = 0
    public var Ports: [String: [PortBinding]?] = [:]
    public var SecondaryIPAddresses: [String]?
    public var SecondaryIPv6Addresses: [String]?
    public var EndpointID = ""
    public var Gateway = ""
    public var GlobalIPv6Address = ""
    public var GlobalIPv6PrefixLen = 0
    public var IPAddress = ""
    public var IPPrefixLen = 0
    public var IPv6Gateway = ""
    public var MacAddress = ""
    public var Networks: [String: EndpointSettings] = [:]
    public init() {}
}

public struct GraphDriver: Codable, Sendable, Equatable {
    public var Name = "overlay2"
    public var Data: [String: String] = [:]
    public init() {}
}

public struct ContainerInspect: Codable, Sendable, Equatable {
    public var Id = ""
    public var Created = ""
    public var Path = ""
    public var Args: [String] = []
    public var State = ContainerState()
    public var Image = ""
    public var ResolvConfPath = ""
    public var HostnamePath = ""
    public var HostsPath = ""
    public var LogPath = ""
    public var Name = ""
    public var RestartCount = 0
    public var Driver = "overlay2"
    public var Platform = "linux"
    public var MountLabel = ""
    public var ProcessLabel = ""
    public var AppArmorProfile = ""
    public var ExecIDs: [String]?
    public var HostConfig = NoodleEngine.HostConfig()
    public var GraphDriver = NoodleEngine.GraphDriver()
    public var SizeRw: Int64?
    public var SizeRootFs: Int64?
    public var Mounts: [MountPoint] = []
    public var Config = ContainerConfig()
    public var NetworkSettings = NoodleEngine.NetworkSettings()
    public init() {}
}

public struct PortSummary: Codable, Sendable, Equatable {
    public var IP: String?
    public var PrivatePort: Int
    public var PublicPort: Int?
    public var `Type`: String
}

public struct ContainerSummary: Codable, Sendable, Equatable {
    public struct HostCfg: Codable, Sendable, Equatable { public var NetworkMode = "default"; public init() {} }
    public struct NetSettings: Codable, Sendable, Equatable { public var Networks: [String: EndpointSettings] = [:]; public init() {} }
    public var Id = ""
    public var Names: [String] = []
    public var Image = ""
    public var ImageID = ""
    public var Command = ""
    public var Created: Int64 = 0
    public var Ports: [PortSummary] = []
    public var Labels: [String: String] = [:]
    public var State = ""
    public var Status = ""
    public var HostConfig = HostCfg()
    public var NetworkSettings = NetSettings()
    public var Mounts: [MountPoint] = []
    public var SizeRw: Int64?
    public var SizeRootFs: Int64?
    public init() {}
}
