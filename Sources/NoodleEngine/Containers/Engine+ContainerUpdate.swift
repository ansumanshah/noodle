import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    public func renameContainer(_ ref: String, to newName: String) async throws {
        let id = try resolveContainerID(ref)
        var name = newName
        if name.hasPrefix("/") { name.removeFirst() }
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]+$", options: .regularExpression) != nil else {
            throw EngineError.invalid("Invalid container name (\(name)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        if let other = containers.values.first(where: { $0.name == name && $0.id != id }) {
            throw EngineError.conflict("Container \"\(other.id)\" holds the name \"/\(name)\"; that name is already in use. Choose a different name, or release this one by renaming or removing its container.")
        }
        var c = containers[id]!
        let old = c.name
        c.name = name
        containers[id] = c
        scheduleSave()
        emit("container", "rename", id: id, attributes: containerAttributes(c, extra: ["oldName": "/" + old]))
        for n in Set(c.endpoints.values.map(\.networkID)) { if let net = networks[n] { await syncDNS(net) } }
    }

    public func updateContainer(_ ref: String, _ u: ContainerUpdateRequest) async throws -> [String] {
        let id = try resolveContainerID(ref)
        return try await withLock(id) {
        guard var c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        if let m = u.Memory { c.hostConfig.Memory = m }
        if let n = u.NanoCpus { c.hostConfig.NanoCpus = n }
        if let s = u.CpuShares { c.hostConfig.CpuShares = s }
        if let q = u.CpuQuota { c.hostConfig.CpuQuota = q }
        if let p = u.CpuPeriod { c.hostConfig.CpuPeriod = p }
        if let p = u.PidsLimit { c.hostConfig.PidsLimit = p }
        try checkCpusetRange(u.CpusetCpus ?? "", u.CpusetMems ?? "")
        if let v = u.CpusetCpus, !v.isEmpty { try Self.validateCpuset(v, flag: "--cpuset-cpus"); c.hostConfig.CpusetCpus = v }
        if let v = u.CpusetMems, !v.isEmpty { try Self.validateCpuset(v, flag: "--cpuset-mems"); c.hostConfig.CpusetMems = v }
        if let r = u.RestartPolicy {
            if c.hostConfig.AutoRemove && !(r.Name.isEmpty || r.Name == "no") { throw EngineError.invalid("Cannot update restart policy on an AutoRemove container") }
            c.hostConfig.RestartPolicy = r
        }
        if c.isRunningLike {
            let hc = c.hostConfig
            let cpus = hc.NanoCpus > 0 ? Double(hc.NanoCpus) / 1e9 : 0
            let quota = hc.NanoCpus > 0 ? 0 : hc.CpuQuota
            try await runtime(id).guest.call(GuestOp.update, ["container": .string(id), "memory": .int(hc.Memory), "cpus": .double(cpus),
                                                  "cpu_quota": .int(quota), "cpu_period": .int(hc.CpuPeriod),
                                                  "memory_swap": .int(hc.MemorySwap), "memory_reservation": .int(hc.MemoryReservation),
                                                  "cpu_shares": .int(hc.CpuShares),
                                                  "cpuset_cpus": .string(hc.CpusetCpus), "cpuset_mems": .string(hc.CpusetMems), "pids_limit": .int(hc.PidsLimit ?? 0)])
        }
        // The guest call awaited: write only the limits onto the current record so a concurrent exit or rm is not undone.
        guard containers[id] != nil else { throw EngineError.notFound("No such container: \(ref)") }
        containers[id]?.hostConfig = c.hostConfig
        scheduleSave()
        emit("container", "update", id: id, attributes: containerAttributes(containers[id]!))
        return [String]()
        }
    }
}
