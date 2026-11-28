import Foundation
import NoodleCore

// MARK: networks and volumes

public struct IPAMPool: Codable, Sendable, Equatable {
    public var Subnet: String?
    public var Gateway: String?
    public var IPRange: String?
    public var AuxiliaryAddresses: [String: String]?
    public init(Subnet: String? = nil, Gateway: String? = nil, IPRange: String? = nil, AuxiliaryAddresses: [String: String]? = nil) {
        self.Subnet = Subnet; self.Gateway = Gateway; self.IPRange = IPRange; self.AuxiliaryAddresses = AuxiliaryAddresses
    }
}

public struct IPAMSettings: Codable, Sendable, Equatable {
    public var Driver = "default"
    public var Options: [String: String]?
    public var Config: [IPAMPool]?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        Driver = c.get(.Driver, "default"); Options = c.opt(.Options); Config = c.opt(.Config)
    }
}

public struct NetworkContainer: Codable, Sendable, Equatable {
    public var Name = ""
    public var EndpointID = ""
    public var MacAddress = ""
    public var IPv4Address = ""
    public var IPv6Address = ""
    public init() {}
}

public struct NetworkResource: Codable, Sendable, Equatable {
    public var Name = ""
    public var Id = ""
    public var Created = ""
    public var Scope = "local"
    public var Driver = "bridge"
    public var EnableIPv4 = true
    public var EnableIPv6 = false
    public var IPAM = IPAMSettings()
    public var Internal = false
    public var Attachable = false
    public var Ingress = false
    public var ConfigOnly = false
    public var Containers: [String: NetworkContainer] = [:]
    public var Options: [String: String] = [:]
    public var Labels: [String: String] = [:]
    public init() {}
}

public struct NetworkCreateRequest: Codable, Sendable, Equatable {
    public var Name = ""
    public var CheckDuplicate: Bool?
    public var Driver = "bridge"
    public var EnableIPv4: Bool?
    public var EnableIPv6 = false
    public var IPAM = IPAMSettings()
    public var Internal = false
    public var Attachable = false
    public var Ingress = false
    public var Options: [String: String]?
    public var Labels: [String: String]?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        Name = c.get(.Name, ""); CheckDuplicate = c.opt(.CheckDuplicate); Driver = c.get(.Driver, "bridge")
        EnableIPv4 = c.opt(.EnableIPv4); EnableIPv6 = c.get(.EnableIPv6, false); IPAM = c.get(.IPAM, IPAMSettings()); Internal = c.get(.Internal, false)
        Attachable = c.get(.Attachable, false); Ingress = c.get(.Ingress, false); Options = c.opt(.Options); Labels = c.opt(.Labels)
    }
}

public struct NetworkConnectRequest: Codable, Sendable, Equatable {
    public var Container = ""
    public var EndpointConfig: EndpointSettings?
    public init() {}
}

public struct VolumeUsageData: Codable, Sendable, Equatable {
    public var Size: Int64 = -1
    public var RefCount: Int = -1
    public init(Size: Int64 = -1, RefCount: Int = -1) { self.Size = Size; self.RefCount = RefCount }
}

public struct Volume: Codable, Sendable, Equatable {
    public var Name = ""
    public var Driver = "local"
    public var Mountpoint = ""
    public var CreatedAt = ""
    public var Labels: [String: String] = [:]
    public var Scope = "local"
    public var Options: [String: String]?
    public var UsageData: VolumeUsageData?
    public init() {}
}

public struct VolumeCreateRequest: Codable, Sendable, Equatable {
    public var Name: String?
    public var Driver: String?
    public var DriverOpts: [String: String]?
    public var Labels: [String: String]?
    public init() {}
}
