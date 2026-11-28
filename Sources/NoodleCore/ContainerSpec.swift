import Foundation

public struct ContainerSpec: Codable, Sendable, Equatable {
    public var layers: [String] = []
    public var argv: [String] = []
    public var env: [String] = []
    public var cwd: String = "/"
    public var user: String = "0:0"
    public var tty = false
    public var stdin = false
    public var hostname = ""
    public var domainname = ""
    public var readOnly = false
    public var privileged = false
    public var capAdd: [String] = []
    public var capDrop: [String] = []
    public var seccomp = "default"
    public var noNewPrivs = false
    public var `init` = false
    public var ulimits: [GuestUlimit] = []
    public var sysctls: [String: String] = [:]
    public var memory: Int64 = 0
    public var cpus: Double = 0
    public var cpuShares: Int64 = 0
    public var cpuQuota: Int64 = 0
    public var cpuPeriod: Int64 = 0
    public var memorySwap: Int64 = 0
    public var memoryReservation: Int64 = 0
    public var cpusetCpus = ""
    public var cpusetMems = ""
    public var pidsLimit: Int64 = 0
    public var shmSize: Int64 = 67_108_864
    public var networkMode = "bridge"
    public var network: GuestNetwork?
    public var dns: [String] = []
    public var dnsSearch: [String] = []
    public var dnsOptions: [String] = []
    public var resolver: GuestResolver?
    public var hosts: [String] = ["127.0.0.1 localhost"]
    public var mounts: [GuestMount] = []

    enum CodingKeys: String, CodingKey {
        case layers, argv, env, cwd, user, tty, stdin, hostname, domainname
        case readOnly = "read_only", privileged
        case capAdd = "cap_add", capDrop = "cap_drop", seccomp
        case noNewPrivs = "no_new_privs", `init`, ulimits, sysctls, memory, cpus
        case cpuQuota = "cpu_quota", cpuPeriod = "cpu_period", memorySwap = "memory_swap", memoryReservation = "memory_reservation"
        case cpusetCpus = "cpuset_cpus", cpusetMems = "cpuset_mems"
        case cpuShares = "cpu_shares", pidsLimit = "pids_limit", shmSize = "shm_size"
        case networkMode = "network_mode", network, dns
        case dnsSearch = "dns_search", dnsOptions = "dns_options", resolver, hosts, mounts
    }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.layers = try c.decodeIfPresent([String].self, forKey: .layers) ?? self.layers
        self.argv = try c.decodeIfPresent([String].self, forKey: .argv) ?? self.argv
        self.env = try c.decodeIfPresent([String].self, forKey: .env) ?? self.env
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? self.cwd
        self.user = try c.decodeIfPresent(String.self, forKey: .user) ?? self.user
        self.tty = try c.decodeIfPresent(Bool.self, forKey: .tty) ?? self.tty
        self.stdin = try c.decodeIfPresent(Bool.self, forKey: .stdin) ?? self.stdin
        self.hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? self.hostname
        self.domainname = try c.decodeIfPresent(String.self, forKey: .domainname) ?? self.domainname
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? self.readOnly
        self.privileged = try c.decodeIfPresent(Bool.self, forKey: .privileged) ?? self.privileged
        self.capAdd = try c.decodeIfPresent([String].self, forKey: .capAdd) ?? self.capAdd
        self.capDrop = try c.decodeIfPresent([String].self, forKey: .capDrop) ?? self.capDrop
        self.seccomp = try c.decodeIfPresent(String.self, forKey: .seccomp) ?? self.seccomp
        self.noNewPrivs = try c.decodeIfPresent(Bool.self, forKey: .noNewPrivs) ?? self.noNewPrivs
        self.`init` = try c.decodeIfPresent(Bool.self, forKey: .`init`) ?? self.`init`
        self.ulimits = try c.decodeIfPresent([GuestUlimit].self, forKey: .ulimits) ?? self.ulimits
        self.sysctls = try c.decodeIfPresent([String: String].self, forKey: .sysctls) ?? self.sysctls
        self.memory = try c.decodeIfPresent(Int64.self, forKey: .memory) ?? self.memory
        self.cpus = try c.decodeIfPresent(Double.self, forKey: .cpus) ?? self.cpus
        self.cpuShares = try c.decodeIfPresent(Int64.self, forKey: .cpuShares) ?? self.cpuShares
        self.cpuQuota = try c.decodeIfPresent(Int64.self, forKey: .cpuQuota) ?? self.cpuQuota
        self.cpuPeriod = try c.decodeIfPresent(Int64.self, forKey: .cpuPeriod) ?? self.cpuPeriod
        self.memorySwap = try c.decodeIfPresent(Int64.self, forKey: .memorySwap) ?? self.memorySwap
        self.memoryReservation = try c.decodeIfPresent(Int64.self, forKey: .memoryReservation) ?? self.memoryReservation
        self.pidsLimit = try c.decodeIfPresent(Int64.self, forKey: .pidsLimit) ?? self.pidsLimit
        self.cpusetCpus = try c.decodeIfPresent(String.self, forKey: .cpusetCpus) ?? self.cpusetCpus
        self.cpusetMems = try c.decodeIfPresent(String.self, forKey: .cpusetMems) ?? self.cpusetMems
        self.shmSize = try c.decodeIfPresent(Int64.self, forKey: .shmSize) ?? self.shmSize
        self.networkMode = try c.decodeIfPresent(String.self, forKey: .networkMode) ?? self.networkMode
        self.dns = try c.decodeIfPresent([String].self, forKey: .dns) ?? self.dns
        self.dnsSearch = try c.decodeIfPresent([String].self, forKey: .dnsSearch) ?? self.dnsSearch
        self.dnsOptions = try c.decodeIfPresent([String].self, forKey: .dnsOptions) ?? self.dnsOptions
        self.hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? self.hosts
        self.mounts = try c.decodeIfPresent([GuestMount].self, forKey: .mounts) ?? self.mounts
        network = try c.decodeIfPresent(GuestNetwork.self, forKey: .network)
        resolver = try c.decodeIfPresent(GuestResolver.self, forKey: .resolver)
    }
}
