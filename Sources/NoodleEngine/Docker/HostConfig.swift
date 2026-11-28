import Foundation
import NoodleCore

public struct HostConfig: Codable, Sendable, Equatable {
    public var Binds: [String]?
    public var ContainerIDFile = ""
    public var LogConfig = NoodleEngine.LogConfig()
    public var NetworkMode = "default"
    public var PortBindings: [String: [PortBinding]?]?
    public var RestartPolicy = NoodleEngine.RestartPolicy()
    public var AutoRemove = false
    public var VolumeDriver = ""
    public var VolumesFrom: [String]?
    public var Mounts: [MountConfig]?
    public var CapAdd: [String]?
    public var CapDrop: [String]?
    public var CgroupnsMode = ""
    public var Dns: [String]?
    public var DnsOptions: [String]?
    public var DnsSearch: [String]?
    public var ExtraHosts: [String]?
    public var GroupAdd: [String]?
    public var IpcMode = "private"
    public var Cgroup = ""
    public var Links: [String]?
    public var OomScoreAdj = 0
    public var PidMode = ""
    public var Privileged = false
    public var PublishAllPorts = false
    public var ReadonlyRootfs = false
    public var SecurityOpt: [String]?
    public var StorageOpt: [String: String]?
    public var Tmpfs: [String: String]?
    public var UTSMode = ""
    public var UsernsMode = ""
    public var ShmSize: Int64 = 0
    public var Sysctls: [String: String]?
    public var Runtime = "runc"
    public var Isolation = ""
    public var CpuShares: Int64 = 0
    public var Memory: Int64 = 0
    public var NanoCpus: Int64 = 0
    public var CgroupParent = ""
    public var Devices: [DeviceMapping]?
    public var DeviceRequests: [DeviceRequest]?
    public var BlkioWeight = 0
    public var CpuPeriod: Int64 = 0
    public var CpuQuota: Int64 = 0
    public var CpusetCpus = ""
    public var CpusetMems = ""
    public var MemoryReservation: Int64 = 0
    public var MemorySwap: Int64 = 0
    public var MemorySwappiness: Int64?
    public var OomKillDisable: Bool?
    public var PidsLimit: Int64?
    public var Init: Bool?
    public var Ulimits: [Ulimit]?

    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        Binds = c.opt(.Binds); ContainerIDFile = c.get(.ContainerIDFile, ""); LogConfig = c.get(.LogConfig, NoodleEngine.LogConfig())
        NetworkMode = c.get(.NetworkMode, "default"); PortBindings = c.opt(.PortBindings)
        RestartPolicy = c.get(.RestartPolicy, NoodleEngine.RestartPolicy()); AutoRemove = c.get(.AutoRemove, false)
        VolumeDriver = c.get(.VolumeDriver, ""); VolumesFrom = c.opt(.VolumesFrom); Mounts = c.opt(.Mounts)
        CapAdd = c.opt(.CapAdd); CapDrop = c.opt(.CapDrop); CgroupnsMode = c.get(.CgroupnsMode, "")
        Dns = c.opt(.Dns); DnsOptions = c.opt(.DnsOptions); DnsSearch = c.opt(.DnsSearch); ExtraHosts = c.opt(.ExtraHosts)
        GroupAdd = c.opt(.GroupAdd); IpcMode = c.get(.IpcMode, "private"); Cgroup = c.get(.Cgroup, ""); Links = c.opt(.Links)
        OomScoreAdj = c.get(.OomScoreAdj, 0); PidMode = c.get(.PidMode, ""); Privileged = c.get(.Privileged, false)
        PublishAllPorts = c.get(.PublishAllPorts, false); ReadonlyRootfs = c.get(.ReadonlyRootfs, false)
        SecurityOpt = c.opt(.SecurityOpt); StorageOpt = c.opt(.StorageOpt); Tmpfs = c.opt(.Tmpfs)
        UTSMode = c.get(.UTSMode, ""); UsernsMode = c.get(.UsernsMode, ""); ShmSize = c.get(.ShmSize, 0)
        Sysctls = c.opt(.Sysctls); Runtime = c.get(.Runtime, "runc"); Isolation = c.get(.Isolation, "")
        CpuShares = c.get(.CpuShares, 0); Memory = c.get(.Memory, 0); NanoCpus = c.get(.NanoCpus, 0)
        CgroupParent = c.get(.CgroupParent, ""); Devices = c.opt(.Devices); DeviceRequests = c.opt(.DeviceRequests); BlkioWeight = c.get(.BlkioWeight, 0)
        CpuPeriod = c.get(.CpuPeriod, 0); CpuQuota = c.get(.CpuQuota, 0); CpusetCpus = c.get(.CpusetCpus, ""); CpusetMems = c.get(.CpusetMems, "")
        MemoryReservation = c.get(.MemoryReservation, 0); MemorySwap = c.get(.MemorySwap, 0)
        MemorySwappiness = c.opt(.MemorySwappiness); OomKillDisable = c.opt(.OomKillDisable); PidsLimit = c.opt(.PidsLimit)
        Init = c.opt(.Init); Ulimits = c.opt(.Ulimits)
    }
}
