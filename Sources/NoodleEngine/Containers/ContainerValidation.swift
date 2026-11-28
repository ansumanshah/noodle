import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// Options that would otherwise be accepted and silently ignored. A clear refusal beats a container that is less isolated or
    /// less constrained than the command line says.
    static func refuseUnsupported(_ hc: HostConfig) throws {
        if hc.PidMode == "host" {
            throw EngineError.invalid("--pid=host is not supported: containers run in a Linux VM, so the host PID namespace would be the VM's, not your Mac's")
        }
        if !hc.CgroupParent.isEmpty {
            throw EngineError.invalid("--cgroup-parent is not supported: Noodle places every container in its own cgroup under its own parent")
        }
        if let d = hc.Devices, let first = d.first {
            throw EngineError.invalid("--device \(first.PathOnHost) is not supported: devices of your Mac cannot be passed into the Linux VM")
        }
        try validateCpuset(hc.CpusetCpus, flag: "--cpuset-cpus")
        try validateCpuset(hc.CpusetMems, flag: "--cpuset-mems")
        try validateCapabilities(hc.CapAdd)
        try validateCapabilities(hc.CapDrop)
        try validatePortBindings(hc.PortBindings)
    }

    /// Docker's own range rules: container ports 1-65535, host ports 0-65535 (0 or empty picks a free one).
    /// Docker rejects sub-millisecond durations (nanoseconds) instead of rounding them. Zero means "use the default".
    static func validateHealthcheck(_ h: HealthConfig?) throws {
        guard let h else { return }
        for (name, value) in [("Interval", h.Interval), ("Timeout", h.Timeout), ("StartPeriod", h.StartPeriod), ("StartInterval", h.StartInterval)] {
            if let value, value > 0, value < 1_000_000 { throw EngineError.invalid("\(name) in Healthcheck cannot be less than 1ms") }
        }
    }

    static func validatePortBindings(_ bindings: [String: [PortBinding]?]?) throws {
        for (key, list) in bindings ?? [:] {
            guard PortSpec.parse(key) != nil else { throw EngineError.invalid("invalid port specification: \"\(key)\"") }
            for b in list ?? [] {
                guard let first = b.HostPort.split(separator: "-").first else { continue }
                guard let p = Int(first), (0...65535).contains(p) else {
                    throw EngineError.invalid("invalid host port \"\(b.HostPort)\" for \(key)")
                }
            }
        }
    }

    /// Names the guest's capability table knows (`cap_names` in guest/agent/src/container.zig). Keep the two in step.
    static let knownCapabilities: Set<String> = [
        "CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID", "KILL", "SETGID", "SETUID",
        "SETPCAP", "LINUX_IMMUTABLE", "NET_BIND_SERVICE", "NET_BROADCAST", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "IPC_OWNER",
        "SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT", "SYS_PTRACE", "SYS_PACCT", "SYS_ADMIN", "SYS_BOOT", "SYS_NICE",
        "SYS_RESOURCE", "SYS_TIME", "SYS_TTY_CONFIG", "MKNOD", "LEASE", "AUDIT_WRITE", "AUDIT_CONTROL", "SETFCAP",
        "MAC_OVERRIDE", "MAC_ADMIN", "SYSLOG", "WAKE_ALARM", "BLOCK_SUSPEND", "AUDIT_READ", "PERFMON", "BPF",
        "CHECKPOINT_RESTORE",
    ]

    /// Docker's rule and text: names match in any case, with or without `CAP_`, and `ALL` stands for every capability.
    static func validateCapabilities(_ names: [String]?) throws {
        for name in names ?? [] {
            let upper = name.uppercased()
            if upper == "ALL" { continue }
            let bare = upper.hasPrefix("CAP_") ? String(upper.dropFirst(4)) : upper
            guard knownCapabilities.contains(bare) else {
                throw EngineError.invalid("unknown capability: \"CAP_\(bare)\"")
            }
        }
    }

    /// One `--add-host name:address` as an /etc/hosts line. Square brackets around an IPv6 address are dropped; the literal `host-gateway` stays for the agent.
    static func hostsLine(extraHost: String) -> String? {
        let parts = extraHost.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        var address = parts[1]
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        return "\(address) \(parts[0])"
    }

    /// Syntax only ("0", "0-3,5"). Whether the CPUs exist in the VM is the guest's call, since only the kernel knows its CPU count.
    static func validateCpuset(_ value: String, flag: String) throws {
        if value.isEmpty { return }
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            let nums = ends.compactMap { $0.isEmpty || !$0.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int($0) }
            guard ends.count <= 2, nums.count == ends.count, nums == nums.sorted() else {
                throw EngineError.invalid("invalid \(flag) \"\(value)\": expected a list such as 0, 0-3 or 0,2-3")
            }
        }
    }

    /// Rejects CPUs and memory nodes the VM does not have, at create time, so the error reaches `docker run` before any attach.
    func checkCpusetRange(_ cpus: String, _ mems: String) throws {
        func top(_ v: String) -> Int {
            v.split(separator: ",").flatMap { $0.split(separator: "-") }.compactMap { Int($0) }.max() ?? 0
        }
        if !cpus.isEmpty {
            try Self.validateCpuset(cpus, flag: "--cpuset-cpus")
            if top(cpus) >= settings.cpus {
                throw EngineError.invalid("invalid --cpuset-cpus \"\(cpus)\": this VM has \(settings.cpus) CPU(s), numbered 0-\(settings.cpus - 1)")
            }
        }
        if !mems.isEmpty {
            try Self.validateCpuset(mems, flag: "--cpuset-mems")
            if top(mems) > 0 {
                throw EngineError.invalid("invalid --cpuset-mems \"\(mems)\": this VM has one memory node, 0")
            }
        }
    }
}
