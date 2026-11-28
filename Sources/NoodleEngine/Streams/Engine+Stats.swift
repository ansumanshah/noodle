import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// One Docker-format sample. Pass the previous sample to fill `precpu_stats`.
    func sample(_ id: String, previous: StatsJSON?) async throws -> StatsJSON {
        guard let c = containers[id] else { throw EngineError.notFound("No such container: \(id)") }
        var out = StatsJSON()
        out.name = "/" + c.name; out.id = c.id
        let now = Date()
        out.read = ISO8601.string(now)
        out.preread = previous?.read ?? "0001-01-01T00:00:00Z"
        if let p = previous { out.precpu_stats = p.cpu_stats }
        let ncpu = settings.cpus
        guard c.status == .running || c.status == .paused else { return out }
        let rt = runtime(for: c)
        let s = try await rt.guest.call(GuestOp.stats, ["container": .string(id)], as: GuestStats.self)
        out.cpu_stats.cpu_usage.total_usage = s.cpuNs
        let split = Self.cpuSplit(s.cpuNs)
        out.cpu_stats.cpu_usage.usage_in_usermode = split.user
        out.cpu_stats.cpu_usage.usage_in_kernelmode = split.kernel
        out.cpu_stats.online_cpus = ncpu
        out.cpu_stats.system_cpu_usage = UInt64(max(0, now.timeIntervalSince(rt.epochStart)) * 1e9) * UInt64(ncpu)
        out.memory_stats.usage = s.memory
        out.memory_stats.limit = s.memoryLimit > 0 ? s.memoryLimit : UInt64(settings.memoryMiB) << 20
        out.memory_stats.stats = ["cache": 0, "inactive_file": 0, "total_inactive_file": 0]
        out.pids_stats.current = s.pids
        out.num_procs = Int(clamping: s.pids)
        out.blkio_stats.io_service_bytes_recursive = [.init(op: "read", value: s.blkRead), .init(op: "write", value: s.blkWrite)]
        var net = StatsJSON.NetStats(); net.rx_bytes = s.netRx; net.tx_bytes = s.netTx
        out.networks = ["eth0": net]
        return out
    }

    /// Stats samples once per second (`stream`), or a single sample. `oneShot` skips the second sample that fills `precpu_stats`.
    public func stats(_ ref: String, stream: Bool = true, oneShot: Bool = false) throws -> AsyncThrowingStream<StatsJSON, Error> {
        let id = try resolveContainerID(ref)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var prev: StatsJSON?
                    if !stream && !oneShot, await self.containers[id]?.isRunningLike == true {
                        prev = try await self.sample(id, previous: nil)
                        try await Task.sleep(for: .milliseconds(600))
                    }
                    while !Task.isCancelled {
                        let s = try await self.sample(id, previous: prev)
                        cont.yield(s)
                        if !stream { break }
                        prev = s
                        if await self.containers[id] == nil { break }
                        try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                    }
                    cont.finish()
                } catch is CancellationError { cont.finish() }
                catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func top(_ ref: String) async throws -> TopResult {
        let id = try resolveContainerID(ref)
        guard let c = containers[id], c.status == .running || c.status == .paused else { throw EngineError.conflict("Container \(ref) is not running") }
        let r = try await runtime(id).guest.call(GuestOp.top, ["container": .string(id)])
        let procs = (r["processes"]?.array ?? []).compactMap { try? $0.decode() as GuestProcess }
        return TopResult(Titles: ["UID", "PID", "PPID", "CMD"],
                         Processes: procs.map { [String($0.uid), String($0.pid), String($0.ppid), $0.cmd] })
    }

    public func changes(_ ref: String) async throws -> [FsChange] {
        let id = try resolveContainerID(ref)
        try await ensureGuestContainer(id)
        let r = try await runtime(id).guest.call(GuestOp.diff, ["container": .string(id)])
        return (r["changes"]?.array ?? []).compactMap { try? $0.decode() as GuestChange }.map { FsChange(Path: $0.path, Kind: $0.kind) }
    }
}
