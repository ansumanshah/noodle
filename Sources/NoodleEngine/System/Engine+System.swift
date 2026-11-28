import Foundation
import NoodleCore

extension Engine {
    public func version() -> VersionInfo {
        var v = VersionInfo()
        v.Version = Self.serverVersion; v.ApiVersion = Self.apiVersion; v.MinAPIVersion = Self.minAPIVersion
        v.GitCommit = "noodle"; v.GoVersion = "swift"; v.KernelVersion = "linux-guest"
        v.BuildTime = "2026-11-04T00:00:00Z"
        v.Components = [.init(Name: "Engine", Version: Self.serverVersion, Details: ["ApiVersion": Self.apiVersion, "MinAPIVersion": Self.minAPIVersion, "Os": "linux", "Arch": "arm64"])]
        return v
    }

    /// `GET /info`. Never boots the VM.
    public func info() async -> SystemInfo {
        var i = SystemInfo()
        let all = Array(containers.values)
        i.ID = String(IDs.random64().prefix(8))
        if let data = try? Data(contentsOf: paths.root.appendingPathComponent("engine-id")), let s = String(data: data, encoding: .utf8) { i.ID = s }
        else { try? Data(i.ID.utf8).write(to: paths.root.appendingPathComponent("engine-id")) }
        i.Containers = all.count
        i.ContainersRunning = all.filter { $0.status == .running }.count
        i.ContainersPaused = all.filter { $0.status == .paused }.count
        i.ContainersStopped = all.filter { !$0.isRunningLike }.count
        i.Images = await imageStore.all().count
        i.SystemTime = ISO8601.string(Date())
        i.NCPU = settings.cpus; i.MemTotal = Int64(settings.memoryMiB) << 20
        i.KernelVersion = "linux-guest"; i.OSVersion = "26"
        i.Name = Host.current().localizedName ?? "noodle"
        i.ServerVersion = Self.serverVersion
        i.NEventsListener = hub.subscriberCount
        i.NFd = 32
        return i
    }

    public func diskUsage() async -> DiskUsage {
        var d = DiskUsage()
        d.Images = await listImages(all: true)
        d.LayersSize = Set(await imageStore.all().flatMap { $0.layers }).reduce(0) { $0 + ($1.unpackedBytes ?? $1.size) }
        d.Containers = containers.values.map { summary($0) }
        var vols: [Volume] = []
        for v in volumes.values.sorted(by: { $0.name < $1.name }) {
            vols.append(volumeResource(v, usage: await volumeBytes(v.name)))
        }
        d.Volumes = vols
        return d
    }

    // MARK: events

    /// Live events, preceded by history newer than `since`. Finishes after `until` when given.
    public func events(since: Int64? = nil, until: Int64? = nil, filters: Filters = Filters()) -> AsyncStream<EventMessage> {
        let live = hub.subscribe()
        let past = since != nil ? hub.snapshot(since: since, until: until) : []
        let hub = self.hub
        _ = hub
        return AsyncStream(bufferingPolicy: .bufferingNewest(EventHub.subscriberBuffer)) { cont in
            let task = Task {
                var sent = Set<Int64>()
                for e in past where Self.eventMatches(e, filters) {
                    if case .dropped = cont.yield(e) { cont.finish(); return }
                    sent.insert(e.timeNano)
                }
                if let until, Int64(Date().timeIntervalSince1970) > until { cont.finish(); return }
                for await e in live {
                    if let until, e.time > until { break }
                    if sent.contains(e.timeNano) { continue }
                    if Self.eventMatches(e, filters), case .dropped = cont.yield(e) { break }
                }
                cont.finish()
            }
            // `until` ends the stream when its time passes, even if no further event arrives.
            let timer = until.map { stop in
                Task {
                    try? await Task.sleep(for: .seconds(max(0, Double(stop) - Date().timeIntervalSince1970) + 0.05))
                    cont.finish()
                }
            }
            cont.onTermination = { _ in task.cancel(); timer?.cancel() }
        }
    }

    nonisolated static func eventMatches(_ e: EventMessage, _ f: Filters) -> Bool {
        if !f["type"].isEmpty, !f["type"].contains(e.Type) { return false }
        if !f["event"].isEmpty, !f["event"].contains(e.Action) { return false }
        if !f["container"].isEmpty, e.Type == "container", !f["container"].contains(where: { e.Actor.ID.hasPrefix($0) || e.Actor.Attributes["name"] == $0 }) { return false }
        if !f["image"].isEmpty, !f["image"].contains(where: { e.Actor.Attributes["image"] == $0 || e.Actor.ID == $0 }) { return false }
        if !f["network"].isEmpty, e.Type == "network", !f["network"].contains(where: { e.Actor.ID.hasPrefix($0) || e.Actor.Attributes["name"] == $0 }) { return false }
        if !f["volume"].isEmpty, e.Type == "volume", !f["volume"].contains(e.Actor.ID) { return false }
        return f.matchLabels(e.Actor.Attributes)
    }

    // MARK: VM control (for the app and CLI)

    public func vmStatus(includeUsage: Bool = false) async -> VMStatus {
        var usage: VMStatus.Usage?
        if includeUsage, let active = await vm.usageConfiguration {
            let sample = try? await guest.sampleUsage()
            if await vm.usageConfiguration?.boot == active.boot {
                usage = VMStatus.Usage(cpus: active.cpus, memoryMiB: active.memoryMiB,
                                       memoryUsed: sample?["memory_used"]?.int.flatMap { UInt64(exactly: $0) },
                                       cpuBusy: sample?["cpu_busy"]?.int.flatMap { UInt64(exactly: $0) },
                                       cpuTotal: sample?["cpu_total"]?.int.flatMap { UInt64(exactly: $0) })
            }
        }
        let readiness = await vm.readiness
        let boot = await vm.bootCount
        return VMStatus(state: readiness.state.rawValue, vmRunning: readiness.vmRunning,
                        guestAgentReady: readiness.vmRunning && readiness.state == .running,
                        cpus: settings.cpus, memoryMiB: settings.memoryMiB, diskGiB: settings.diskGiB,
                        lastBootMilliseconds: await vm.lastBootDuration?.totalMilliseconds, bootCount: boot,
                        usage: readiness.state == .running ? usage : nil)
    }

    /// `POST /noodle/vm/sleep`: sleep the VMs now unless a container runs. Reports whether any VM went to sleep.
    public func sleepVMsIfIdle() async -> Bool {
        guard !containers.values.contains(where: { $0.status == .running }) else { return false }
        var slept = false
        for rt in runtimes { if await rt.vm.sleepIfIdle() { slept = true } }
        return slept
    }

    /// Persist new VM sizing. Takes effect at the next cold boot.
    public func updateVMSettings(cpus: Int? = nil, memoryMiB: Int? = nil) async throws {
        let disk = VMSettings.load(paths: paths)
        settings.approvedDirectories = disk.approvedDirectories
        if let cpus { settings.cpus = max(1, cpus) }
        if let memoryMiB { settings.memoryMiB = max(256, memoryMiB) }
        // The loopback switch on disk wins over the value this daemon started with (it applies at the next start).
        try settings.keepingFileManagedValues(from: disk).save(paths: paths)
        for rt in runtimes { await rt.vm.updateSettings(settings) }
    }

    public struct SharedFolders: Codable, Sendable {
        /// nil: never decided (off).
        public var Enabled: Bool?
        public var Restarted: Bool?
        /// Request only: restart a running workload VM even when the value is unchanged (a folder was removed).
        public var Restart: Bool?
        public init(Enabled: Bool?, Restarted: Bool? = nil) { self.Enabled = Enabled; self.Restarted = Restarted }
    }

    public func workloadSharedFolders() -> SharedFolders { SharedFolders(Enabled: settings.workloadSharedFolders) }

    /// "Let Kubernetes use your shared folders". Saves vm.json, then restarts a running workload VM when
    /// the value changed: its sharing device exists only from boot, and turning off must drop shares already handed
    /// out. Containers in that VM exit with 137, as for any workload VM stop.
    public func setWorkloadSharedFolders(_ on: Bool, forceRestart: Bool = false) async throws -> SharedFolders {
        var disk = VMSettings.load(paths: paths)
        disk.workloadSharedFolders = on
        try disk.save(paths: paths)
        let changed = (settings.workloadSharedFolders == true) != on
        settings.workloadSharedFolders = on
        for rt in runtimes { await rt.vm.updateSettings(settings) }
        let running = await workload.vm.isRunning
        let restart = (changed || forceRestart) && running
        if restart { await workload.vm.sleepNow() }
        return SharedFolders(Enabled: on, Restarted: restart)
    }
}
