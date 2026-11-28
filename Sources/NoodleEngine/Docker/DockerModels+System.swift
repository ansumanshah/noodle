import Foundation
import NoodleCore

// MARK: system

public struct VersionInfo: Codable, Sendable, Equatable {
    public struct Component: Codable, Sendable, Equatable { public var Name: String; public var Version: String; public var Details: [String: String]? }
    public struct PlatformInfo: Codable, Sendable, Equatable { public var Name: String }
    public var Platform = PlatformInfo(Name: "Noodle")
    public var Components: [Component] = []
    public var Version = ""
    public var ApiVersion = ""
    public var MinAPIVersion = ""
    public var GitCommit = ""
    public var GoVersion = ""
    public var Os = "linux"
    public var Arch = "arm64"
    public var KernelVersion = ""
    public var BuildTime = ""
    public init() {}
}

public struct SystemInfo: Codable, Sendable, Equatable {
    public struct Runtime: Codable, Sendable, Equatable { public var path: String }
    public struct SwarmInfo: Codable, Sendable, Equatable { public var NodeID = ""; public var NodeAddr = ""; public var LocalNodeState = "inactive"; public var ControlAvailable = false; public var Error = ""; public var RemoteManagers: [String]?; public init() {} }
    public var ID = ""
    public var Containers = 0
    public var ContainersRunning = 0
    public var ContainersPaused = 0
    public var ContainersStopped = 0
    public var Images = 0
    public var Driver = "overlay2"
    public var DriverStatus: [[String]] = [["Backing Filesystem", "extfs"], ["Supports d_type", "true"]]
    public var Plugins: [String: [String]] = ["Volume": ["local"], "Network": ["bridge", "host", "null"], "Authorization": [], "Log": ["json-file"]]
    public var MemoryLimit = true
    public var SwapLimit = false
    public var CpuCfsPeriod = true
    public var CpuCfsQuota = true
    public var CPUShares = true
    public var CPUSet = true
    public var PidsLimit = true
    public var IPv4Forwarding = true
    public var Debug = false
    public var NFd = 0
    public var NGoroutines = 0
    public var SystemTime = ""
    public var LoggingDriver = "json-file"
    public var CgroupDriver = "cgroupfs"
    public var CgroupVersion = "2"
    public var NEventsListener = 0
    public var KernelVersion = ""
    public var OperatingSystem = "Noodle"
    public var OSVersion = ""
    public var OSType = "linux"
    public var Architecture = "aarch64"
    public var IndexServerAddress = "https://index.docker.io/v1/"
    public var NCPU = 0
    public var MemTotal: Int64 = 0
    public var DockerRootDir = "/var/lib/docker"
    public var HttpProxy = ""
    public var HttpsProxy = ""
    public var NoProxy = ""
    public var Name = ""
    public var Labels: [String] = []
    public var ExperimentalBuild = false
    public var ServerVersion = ""
    public var Runtimes: [String: Runtime] = ["runc": Runtime(path: "runc")]
    public var DefaultRuntime = "runc"
    public var Swarm = SwarmInfo()
    public var LiveRestoreEnabled = false
    public var Isolation = ""
    public var InitBinary = "docker-init"
    public var SecurityOptions: [String] = ["name=seccomp,profile=builtin", "name=cgroupns"]
    public var Warnings: [String] = []
    public init() {}
}

public struct DiskUsage: Codable, Sendable {
    public var LayersSize: Int64 = 0
    public var Images: [ImageSummary] = []
    public var Containers: [ContainerSummary] = []
    public var Volumes: [Volume] = []
    public var BuildCache: [EmptyStruct] = []
    public init() {}
}

public struct EventActor: Codable, Sendable, Equatable {
    public var ID: String
    public var Attributes: [String: String]
}

public struct EventMessage: Codable, Sendable, Equatable {
    public var `Type`: String
    public var Action: String
    public var Actor: EventActor
    public var scope = "local"
    public var time: Int64
    public var timeNano: Int64
    // legacy fields kept for old clients
    public var status: String?
    public var id: String?
    public var from: String?
}

// MARK: stats (snake_case keys, as Docker emits them)

public struct StatsJSON: Codable, Sendable, Equatable {
    public struct CPUUsage: Codable, Sendable, Equatable {
        public var total_usage: UInt64 = 0
        public var usage_in_kernelmode: UInt64 = 0
        public var usage_in_usermode: UInt64 = 0
        public var percpu_usage: [UInt64]?
    }
    public struct Throttling: Codable, Sendable, Equatable { public var periods: UInt64 = 0; public var throttled_periods: UInt64 = 0; public var throttled_time: UInt64 = 0 }
    public struct CPUStats: Codable, Sendable, Equatable {
        public var cpu_usage = CPUUsage()
        public var system_cpu_usage: UInt64 = 0
        public var online_cpus: Int = 0
        public var throttling_data = Throttling()
    }
    public struct MemoryStats: Codable, Sendable, Equatable {
        public var usage: UInt64 = 0
        public var max_usage: UInt64 = 0
        public var stats: [String: UInt64] = [:]
        public var limit: UInt64 = 0
    }
    public struct PidsStats: Codable, Sendable, Equatable { public var current: UInt64 = 0 }
    public struct BlkioEntry: Codable, Sendable, Equatable { public var major: Int = 0; public var minor: Int = 0; public var op: String; public var value: UInt64 }
    public struct BlkioStats: Codable, Sendable, Equatable { public var io_service_bytes_recursive: [BlkioEntry]? }
    public struct NetStats: Codable, Sendable, Equatable {
        public var rx_bytes: UInt64 = 0, rx_packets: UInt64 = 0, rx_errors: UInt64 = 0, rx_dropped: UInt64 = 0
        public var tx_bytes: UInt64 = 0, tx_packets: UInt64 = 0, tx_errors: UInt64 = 0, tx_dropped: UInt64 = 0
    }
    public var read = ""
    public var preread = ""
    public var pids_stats = PidsStats()
    public var blkio_stats = BlkioStats()
    public var num_procs: Int = 0
    public var storage_stats = EmptyStruct()
    public var cpu_stats = CPUStats()
    public var precpu_stats = CPUStats()
    public var memory_stats = MemoryStats()
    public var name = ""
    public var id = ""
    public var networks: [String: NetStats]?
    public init() {}
}

/// One row of `GET /images/search` (Docker uses snake_case here).
public struct ImageSearchItem: Codable, Sendable, Equatable {
    public var description: String
    public var is_official: Bool
    public var is_automated: Bool
    public var name: String
    public var star_count: Int
}

/// `X-Docker-Container-Path-Stat` payload for `HEAD/GET /containers/{id}/archive`.
public struct PathStat: Codable, Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var mode: UInt32
    public var mtime: String
    public var linkTarget: String
}
