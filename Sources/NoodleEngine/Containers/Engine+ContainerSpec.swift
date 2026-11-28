import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    func buildSpec(_ c: ContainerRecord, primary: EndpointRecord?, net: NetworkRecord?) throws -> ContainerSpec {
        let hc = c.hostConfig, cfg = c.config
        var s = ContainerSpec()
        s.argv = (cfg.Entrypoint ?? []) + (cfg.Cmd ?? [])
        let links = try linkedContainers(c)
        var env = Self.linkEnv(links, of: c) + (cfg.Env ?? [])
        if !env.contains(where: { $0.hasPrefix("HOSTNAME=") }) { env.append("HOSTNAME=" + (cfg.Hostname.isEmpty ? c.shortID : cfg.Hostname)) }
        if cfg.Tty && !env.contains(where: { $0.hasPrefix("TERM=") }) { env.append("TERM=xterm") }
        s.env = env
        s.cwd = cfg.WorkingDir.isEmpty ? "/" : cfg.WorkingDir
        s.user = cfg.User.isEmpty ? "0:0" : cfg.User
        s.tty = cfg.Tty; s.stdin = cfg.OpenStdin
        s.hostname = cfg.Hostname.isEmpty ? c.shortID : cfg.Hostname
        s.domainname = cfg.Domainname
        s.readOnly = hc.ReadonlyRootfs; s.privileged = hc.Privileged
        s.capAdd = hc.CapAdd ?? []; s.capDrop = hc.CapDrop ?? []
        for opt in hc.SecurityOpt ?? [] {
            if Self.isUnconfined(opt) { s.seccomp = "unconfined" }
            if opt == "no-new-privileges" || opt == "no-new-privileges=true" || opt == "no-new-privileges:true" { s.noNewPrivs = true }
        }
        s.`init` = hc.Init ?? false
        let limitNames: Set<String> = ["cpu", "fsize", "data", "stack", "core", "rss", "nproc", "nofile", "memlock", "as", "locks", "sigpending", "msgqueue", "nice", "rtprio", "rttime"]
        for limit in hc.Ulimits ?? [] {
            guard limitNames.contains(limit.Name), limit.Soft >= -1, limit.Hard >= -1,
                  limit.Hard == -1 || (limit.Soft != -1 && limit.Soft <= limit.Hard) else {
                throw EngineError.invalid("invalid ulimit: \(limit.Name)")
            }
            s.ulimits.append(GuestUlimit(name: limit.Name, soft: limit.Soft, hard: limit.Hard))
        }
        s.sysctls = hc.Sysctls ?? [:]
        for (key, value) in s.sysctls {
            guard Self.isNetSysctl(key, value: value), c.primaryNetwork != "host", !c.primaryNetwork.hasPrefix("container:") else {
                throw EngineError.invalid("unsupported sysctl or shared network namespace: \(key)")
            }
        }
        s.memory = hc.Memory
        s.cpus = hc.NanoCpus > 0 ? Double(hc.NanoCpus) / 1e9 : 0
        if hc.NanoCpus <= 0, hc.CpuQuota > 0 { s.cpuQuota = hc.CpuQuota; s.cpuPeriod = hc.CpuPeriod }
        s.memorySwap = hc.MemorySwap; s.memoryReservation = hc.MemoryReservation
        s.cpusetCpus = hc.CpusetCpus; s.cpusetMems = hc.CpusetMems
        s.cpuShares = hc.CpuShares; s.pidsLimit = hc.PidsLimit.map { max($0, 0) } ?? 0
        s.shmSize = hc.ShmSize > 0 ? hc.ShmSize : 67_108_864
        switch c.primaryNetwork {
        case "host": s.networkMode = "host"
        case "none": s.networkMode = "none"
        case let m where m.hasPrefix("container:"):
            let target = try resolveContainerID(String(m.dropFirst(10)))
            // Names can change owner between create and start.
            if let t = containers[target], Self.usesWorkload(t) != Self.usesWorkload(c) {
                throw EngineError.invalid("the network of container \(t.name) cannot be shared: privileged or unconfined containers and ordinary containers run in different VMs")
            }
            s.networkMode = "container:" + target
        default:
            s.networkMode = "bridge"
            if let e = primary, let n = net, !e.ip.isEmpty || e.ip6 != nil {
                s.network = GuestNetwork(name: n.name, ip: e.ip, gateway: n.gateway, prefix: IPv4Net(cidr: n.subnet)?.prefix ?? 0, mac: e.mac)
                if let ip6 = e.ip6 {
                    s.network?.ip6 = ip6; s.network?.gateway6 = n.gateway6
                    s.network?.prefix6 = n.subnet6.flatMap { IPv6Net(cidr: $0) }?.prefix
                }
            }
        }
        let customDNS = (hc.Dns ?? []).isEmpty ? nil : hc.Dns
        s.resolver = guestResolver(for: c)
        if s.resolver != nil || sharesEmbeddedResolver(c) {
            s.dns = [Self.embeddedResolver]
        } else {
            s.dns = customDNS ?? (net.map { [$0.gateway] } ?? [])
        }
        s.dnsSearch = hc.DnsSearch ?? []; s.dnsOptions = hc.DnsOptions ?? []
        var hosts = ["127.0.0.1 localhost", "::1 localhost ip6-localhost ip6-loopback"]
        if let e = primary, !e.ip.isEmpty {
            hosts.append(s.domainname.isEmpty ? "\(e.ip) \(s.hostname)" : "\(e.ip) \(s.hostname).\(s.domainname) \(s.hostname)")
        }
        if let ip6 = primary?.ip6 {
            hosts.append(s.domainname.isEmpty ? "\(ip6) \(s.hostname)" : "\(ip6) \(s.hostname).\(s.domainname) \(s.hostname)")
        }
        hosts += Self.linkHosts(links)
        var sawHostGateway = false
        for h in hc.ExtraHosts ?? [] {
            guard let line = Self.hostsLine(extraHost: h) else { continue }
            if h.hasPrefix("host.docker.internal:") { sawHostGateway = true }
            hosts.append(line)
        }
        // `host-gateway` is resolved by the agent to the VM's default gateway, i.e. the Mac.
        // A --network none container cannot reach it, and leaving the name out lets it start before the VM has a lease.
        if !sawHostGateway, c.primaryNetwork != "none" { hosts.append("host-gateway host.docker.internal") }
        s.hosts = hosts
        s.mounts = c.guestMounts
        return s
    }
}
