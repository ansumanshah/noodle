import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: mounts

    func sharedHostPath(_ p: String) throws -> String {
        guard p.hasPrefix("/") else { throw EngineError.invalid("bind source path must be absolute: \(p)") }
        return URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Noodle's own API socket or the conventional `/var/run/docker.sock` asks for the Docker API, as Docker Desktop reads it.
    /// `:ro` does not restrict the relayed API. Exact path matches only: `docker.sock/..` or a trailing slash is a plain bind.
    func isDockerSocketSource(_ src: String) -> Bool {
        guard src.hasPrefix("/"), !src.hasSuffix("/"), !src.split(separator: "/").contains("..") else { return false }
        if src == "/var/run/docker.sock" || src == "/run/docker.sock" { return true }
        let own = paths.socket.path
        return src == own || (try? sharedHostPath(src)) == (try? sharedHostPath(own))
    }

    /// Privileged containers bind only approved folders, and only while the workload VM booted with sharing on.
    /// Approvals are read from disk so a removed folder stops the next start; the switch is the one this daemon applied.
    func validateWorkloadBinds(_ c: ContainerRecord) throws {
        for m in c.guestMounts where m.kind == "bind" { try validateWorkloadBind(m.source) }
    }

    func validateWorkloadBind(_ path: String) throws {
        var check = VMSettings.load(paths: paths)
        check.workloadSharedFolders = settings.workloadSharedFolders
        if let refusal = check.workloadBindRefusal(path) { throw EngineError.invalid(refusal) }
    }

    func validateBindSource(_ path: String) throws {
        guard try sharedHostPath(path) == path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else {
            throw EngineError.invalid("bind source path does not exist: \(path)")
        }
        guard type == .typeDirectory || type == .typeRegular else {
            throw EngineError.invalid("bind source must be a regular file or directory: \(path)")
        }
        if type == .typeRegular && !VMSettings.load(paths: paths).approvesFile(path) {
            let folder = (path as NSString).deletingLastPathComponent
            throw EngineError.invalid("file bind requires an approved folder: the VM can only share whole folders, so containers would see everything next to \(path). To allow that, run: noodle share add \"\(folder)\" (or bind the folder itself with -v \(folder):/dir, which needs no approval)")
        }
    }

    func resolveMounts(hc: HostConfig, cfg: ContainerConfig, imageVolumes: [String], workload: Bool = false) throws -> (points: [MountPoint], guest: [GuestMount]) {
        var points: [MountPoint] = []
        var guestMounts: [GuestMount] = []
        func covered(_ target: String) -> Bool { points.contains { $0.Destination == target } }

        func addBind(_ src: String, _ dst: String, ro: Bool, create: Bool) throws {
            if src == SSHAgent.hostSource {
                var m = MountPoint(); m.Type = "bind"; m.Source = src; m.Destination = dst; m.RW = !ro; m.Mode = ro ? "ro" : ""; m.Propagation = "rprivate"
                points.append(m)
                guestMounts.append(GuestMount(kind: "agent", source: src, target: dst, readOnly: ro))
                return
            }
            if isDockerSocketSource(src) {
                var m = MountPoint(); m.Type = "bind"; m.Source = src; m.Destination = dst; m.RW = !ro; m.Mode = ro ? "ro" : ""; m.Propagation = "rprivate"
                points.append(m)
                guestMounts.append(GuestMount(kind: "docker", source: src, target: dst, readOnly: ro))
                return
            }
            let path = try sharedHostPath(src)
            // refuse before creating anything on the Mac
            if workload { try validateWorkloadBind(path) }
            if !FileManager.default.fileExists(atPath: path) {
                if create { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
                else { throw EngineError.invalid("invalid mount config for type \"bind\": bind source path does not exist: \(src)") }
            }
            try validateBindSource(path)
            var m = MountPoint(); m.Type = "bind"; m.Source = path; m.Destination = dst; m.RW = !ro; m.Mode = ro ? "ro" : ""; m.Propagation = "rprivate"
            points.append(m)
            guestMounts.append(GuestMount(kind: "bind", source: path, target: dst, readOnly: ro))
        }
        func addVolume(_ name: String, _ dst: String, ro: Bool, anonymous: Bool = false, noCopy: Bool = false) throws {
            try checkVolumeAvailable(name)
            if volumes[name] == nil {
                try Self.validateVolumeName(name)
                volumes[name] = VolumeRecord(name: name, created: Date(), driver: "local", anonymous: anonymous)
                emit("volume", "create", id: name, attributes: ["driver": "local"])
            }
            var m = MountPoint(); m.Type = "volume"; m.Name = name; m.Source = "\(Self.volumeRoot)/\(name)/_data"; m.Destination = dst
            m.Driver = "local"; m.RW = !ro; m.Mode = ro ? "ro" : "z"; m.Propagation = ""
            points.append(m)
            guestMounts.append(GuestMount(kind: "volume", source: name, target: dst, readOnly: ro, noCopy: noCopy))
        }
        func addTmpfs(_ dst: String, size: Int64) {
            var m = MountPoint(); m.Type = "tmpfs"; m.Source = ""; m.Destination = dst; m.RW = true
            points.append(m)
            guestMounts.append(GuestMount(kind: "tmpfs", target: dst, tmpfsSize: size))
        }

        for vf in hc.VolumesFrom ?? [] {
            let parts = vf.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(parts.count), !parts[0].isEmpty,
                  parts.count == 1 || ["ro", "rw"].contains(parts[1]) else {
                throw EngineError.invalid("invalid volumes-from specification: '\(vf)'")
            }
            let src = try resolveContainerID(parts[0])
            let ro = parts.count == 2 && parts[1] == "ro"
            for (m, g) in zip(containers[src]!.mounts, containers[src]!.guestMounts) where !covered(m.Destination) {
                var mm = m; if ro { mm.RW = false; mm.Mode = "ro" }
                points.append(mm)
                var gg = g; if ro { gg.readOnly = true }
                guestMounts.append(gg)
            }
        }
        for b in hc.Binds ?? [] {
            let parts = b.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1: try addVolume(IDs.random64(), parts[0], ro: false, anonymous: true)
            case 2, 3:
                let opts = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
                let ro = opts.contains("ro")
                if parts[0].hasPrefix("/") || parts[0].hasPrefix("~") || parts[0].hasPrefix(".") {
                    try addBind(parts[0], parts[1], ro: ro, create: true)
                } else {
                    guard !parts[0].isEmpty else { throw EngineError.invalid("invalid volume specification: '\(b)'") }
                    try addVolume(parts[0], parts[1], ro: ro, noCopy: opts.contains("nocopy"))
                }
            default: throw EngineError.invalid("invalid volume specification: '\(b)'")
            }
        }
        for m in hc.Mounts ?? [] {
            guard m.Target.hasPrefix("/") else { throw EngineError.invalid("invalid mount config: mount path must be absolute: \(m.Target)") }
            switch m.`Type` {
            case "bind": try addBind(m.Source, m.Target, ro: m.ReadOnly, create: m.BindOptions?.CreateMountpoint ?? false)
            case "volume":
                if m.Source.isEmpty { try addVolume(IDs.random64(), m.Target, ro: m.ReadOnly, anonymous: true, noCopy: m.VolumeOptions?.NoCopy ?? false) }
                else { try addVolume(m.Source, m.Target, ro: m.ReadOnly, noCopy: m.VolumeOptions?.NoCopy ?? false) }
            case "tmpfs":
                let size = m.TmpfsOptions?.SizeBytes ?? 0
                guard size >= 0 else { throw EngineError.invalid("tmpfs size must not be negative") }
                addTmpfs(m.Target, size: size)
            default: throw EngineError.invalid("mount type unknown: \(m.`Type`)")
            }
        }
        for (target, opts) in hc.Tmpfs ?? [:] {
            var size: Int64 = 0
            for o in opts.split(separator: ",") where o.hasPrefix("size=") { size = try Self.parseSize(String(o.dropFirst(5))) }
            addTmpfs(target, size: size)
        }
        for target in Set((cfg.Volumes ?? [:]).keys).union(imageVolumes) where !covered(target) {
            try addVolume(IDs.random64(), target, ro: false, anonymous: true)
        }
        let order = zip(points, guestMounts).sorted { $0.0.Destination.split(separator: "/").count < $1.0.Destination.split(separator: "/").count }
        return (order.map(\.0), order.map(\.1))
    }

    static func parseSize(_ s: String) throws -> Int64 {
        var number = s.lowercased()
        if number.hasSuffix("b") { number.removeLast() }
        let mult: Int64
        switch number.last {
        case "k": mult = 1 << 10; number.removeLast()
        case "m": mult = 1 << 20; number.removeLast()
        case "g": mult = 1 << 30; number.removeLast()
        default: mult = 1
        }
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(number) else {
            throw EngineError.invalid("invalid tmpfs size: '\(s)'")
        }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: mult)
        guard !overflow else { throw EngineError.invalid("tmpfs size is too large: '\(s)'") }
        return bytes
    }
}
