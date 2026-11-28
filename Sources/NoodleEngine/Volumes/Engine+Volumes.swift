import Foundation
import NoodleCore

// MARK: - Volumes

extension Engine {
    static let volumeRoot = "/var/lib/docker/volumes"

    func volumeResource(_ v: VolumeRecord, usage: Int64? = nil) -> Volume {
        var r = Volume()
        r.Name = v.name; r.Driver = v.driver; r.Mountpoint = "\(Self.volumeRoot)/\(v.name)/_data"
        r.CreatedAt = ISO8601.string(v.created); r.Labels = v.labels
        r.Options = v.options.isEmpty ? nil : v.options
        let refs = containers.values.filter { $0.mounts.contains { $0.Name == v.name } }.count
        r.UsageData = VolumeUsageData(Size: usage ?? -1, RefCount: refs)
        return r
    }

    static func validateVolumeName(_ name: String) throws {
        guard name.utf8.count <= 255, name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]+$", options: .regularExpression) != nil else {
            throw EngineError.invalid("\"\(name)\" includes invalid characters for a local volume name, only \"[a-zA-Z0-9][a-zA-Z0-9_.-]\" are allowed")
        }
    }

    public func createVolume(_ req: VolumeCreateRequest) throws -> Volume {
        let name = (req.Name?.isEmpty == false) ? req.Name! : IDs.random64()
        try checkVolumeAvailable(name)
        if let existing = volumes[name] { return volumeResource(existing) }
        try Self.validateVolumeName(name)
        if let d = req.Driver, !d.isEmpty, d != "local" { throw EngineError.invalid("volume driver \(d) not found") }
        let v = VolumeRecord(name: name, created: Date(), labels: req.Labels ?? [:], options: req.DriverOpts ?? [:],
                             driver: "local", anonymous: req.Name == nil)
        volumes[name] = v
        scheduleSave()
        emit("volume", "create", id: name, attributes: ["driver": "local"])
        return volumeResource(v)
    }

    public func listVolumes(filters: Filters = Filters()) -> [Volume] {
        volumes.values
            .filter { v in
                if !filters.regexMatches("name", v.name) { return false }
                if !filters["driver"].isEmpty, !filters["driver"].contains(v.driver) { return false }
                if let dangling = filters.bool("dangling") {
                    let used = containers.values.contains { $0.mounts.contains { $0.Name == v.name } }
                    if dangling == used { return false }
                }
                return filters.matchLabels(v.labels)
            }
            .sorted { $0.name < $1.name }
            .map { volumeResource($0) }
    }

    public func inspectVolume(_ name: String) async throws -> Volume {
        guard let v = volumes[name] else { throw EngineError.notFound("get \(name): no such volume") }
        var size: Int64?
        size = await volumeBytes(name)
        return volumeResource(v, usage: size)
    }

    func checkVolumeAvailable(_ name: String) throws {
        if deletingVolumes.contains(name) { throw EngineError.conflict("volume \(name) is being removed") }
    }

    public func removeVolume(_ name: String, force: Bool = false) async throws {
        try await withLock("volume:\(name)") {
            guard let record = volumes[name] else {
                if force { return }
                throw EngineError.notFound("get \(name): no such volume")
            }
            if let user = containers.values.first(where: { $0.mounts.contains { $0.Name == name } }) {
                throw EngineError.conflict("remove \(name): volume is in use - [\(user.id)]")
            }
            deletingVolumes.insert(name)
            defer { deletingVolumes.remove(name) }
            // A volume can exist in either VM (privileged containers use the workload VM's own disk).
            let targets = cleanupRuntimes()
            var online: [GuestRuntime] = []
            for rt in targets where await rt.vm.isRunning { online.append(rt) }
            for rt in online { try await rt.guest.call(GuestOp.volumeRemove, ["name": .string(name)], boot: false) }
            let pending = pendingRemovals
            volumes[name] = nil
            for rt in targets {
                if online.contains(where: { $0 === rt }) { updatePending(rt) { $0.volumes.removeAll { $0 == name } } }
                else if !pendingLists(rt).volumes.contains(name) { updatePending(rt) { $0.volumes.append(name) } }
            }
            do { try persistState() } catch {
                volumes[name] = record
                pendingRemovals = pending
                throw error
            }
            emit("volume", "destroy", id: name, attributes: ["driver": "local"])
        }
    }

    public func pruneVolumes(filters: Filters = Filters(), all: Bool = false) async -> VolumePruneResponse {
        var out = VolumePruneResponse()
        for v in volumes.values where filters.matchLabels(v.labels) {
            if !all && !v.anonymous { continue }
            if containers.values.contains(where: { $0.mounts.contains { $0.Name == v.name } }) { continue }
            let size = await volumeBytes(v.name) ?? 0
            if (try? await removeVolume(v.name)) != nil { out.VolumesDeleted.append(v.name); out.SpaceReclaimed = Self.saturatingBytes(out.SpaceReclaimed, size) }
        }
        return out
    }

    /// Bytes a volume uses in the VMs that are awake, or nil when none of them has it.
    func volumeBytes(_ name: String) async -> Int64? {
        var total: Int64?
        for rt in cleanupRuntimes() where await rt.vm.isRunning && !pendingLists(rt).volumes.contains(name) {
            if let r = try? await rt.guest.call(GuestOp.volumeSize, ["name": .string(name)], boot: false), let b = r["bytes"]?.int { total = Self.saturatingBytes(total ?? 0, b) }
        }
        return total
    }

    // Under the per-volume lock, persist the ACK before a new incarnation may write any data.
    func removePendingGuestVolume(_ name: String, _ rt: GuestRuntime) async throws {
        guard pendingLists(rt).volumes.contains(name) else { return }
        try await rt.guest.call(GuestOp.volumeRemove, ["name": .string(name)], boot: false)
        updatePending(rt) { $0.volumes.removeAll { $0 == name } }
        do { try persistState() } catch {
            updatePending(rt) { $0.volumes.append(name) }
            throw error
        }
    }

    func ensureGuestVolume(_ name: String, in rt: GuestRuntime) async throws {
        try await withLock("volume:\(name)") {
            try await removePendingGuestVolume(name, rt)
            try await rt.guest.call(GuestOp.volumeCreate, ["name": .string(name)])
        }
    }
}
