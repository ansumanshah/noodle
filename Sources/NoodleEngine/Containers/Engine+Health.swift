import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// `resume` keeps the current health state, as after unpause.
    func startHealth(_ id: String, resume: Bool = false) {
        stopHealth(id)
        guard var c = containers[id], let config = c.config.Healthcheck,
              let command = Self.healthCommand(config), c.status == .running else { return }
        if !resume || c.health == nil { c.health = HealthState() }
        containers[id] = c
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.monitorHealth(id, token: token, config: config, command: command)
        }
        healthTasks[id] = (token, task)
    }

    func stopHealth(_ id: String) {
        healthTasks.removeValue(forKey: id)?.task.cancel()
    }

    static func healthCommand(_ config: HealthConfig) -> [String]? {
        guard let test = config.Test, test.count > 1 else { return nil }
        switch test[0] {
        case "CMD": return Array(test.dropFirst())
        case "CMD-SHELL": return ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        default: return nil
        }
    }

    private func monitorHealth(_ id: String, token: UUID, config: HealthConfig, command: [String]) async {
        while !Task.isCancelled {
            guard let c = containers[id], healthTasks[id]?.token == token, c.isRunningLike else { return }
            let startPeriod = max(config.StartPeriod ?? 0, 0)
            let inStartPeriod = c.health?.Status == "starting" && Date().timeIntervalSince(c.startedAt ?? Date()) < Double(startPeriod) / 1e9
            let interval = inStartPeriod ? Self.healthDuration(config.StartInterval, default: 5_000_000_000) : Self.healthDuration(config.Interval, default: 30_000_000_000)
            do { try await Task.sleep(nanoseconds: interval) } catch { return }
            // A paused container ends its monitor (no idle wakeups); unpause starts a new one.
            guard let current = containers[id], current.status == .running, healthTasks[id]?.token == token else { return }
            let start = Date()
            let result: (Int, String)
            do {
                result = try await Self.healthProbe(guest: runtime(for: current).guest, containerID: id, config: current.config, command: command,
                                                    timeout: Self.healthDuration(config.Timeout, default: 30_000_000_000))
            } catch is CancellationError { return }
            catch { result = (-1, String(describing: error)) }
            guard var updated = containers[id], updated.status == .running, healthTasks[id]?.token == token,
                  var health = updated.health else { continue }
            let previous = health.Status
            let entry = HealthState.LogEntry(Start: ISO8601.string(start), End: ISO8601.string(Date()), ExitCode: result.0, Output: result.1)
            let grace = start.timeIntervalSince(updated.startedAt ?? start) < Double(startPeriod) / 1e9
            let retries = config.Retries ?? 0
            Self.applyHealthResult(&health, entry: entry, retries: retries > 0 ? retries : 3, inStartPeriod: grace)
            updated.health = health
            containers[id] = updated
            scheduleSave()
            if health.Status != previous {
                emit("container", "health_status: " + health.Status, id: id, attributes: containerAttributes(updated))
            }
        }
    }

    static func healthDuration(_ value: Int64?, default fallback: UInt64) -> UInt64 {
        guard let value, value > 0 else { return fallback }
        return UInt64(value)
    }

    static func applyHealthResult(_ health: inout HealthState, entry: HealthState.LogEntry, retries: Int, inStartPeriod: Bool) {
        health.Log.append(entry)
        if health.Log.count > 5 { health.Log.removeFirst(health.Log.count - 5) }
        if entry.ExitCode == 0 {
            health.FailingStreak = 0
            health.Status = "healthy"
        } else if !(health.Status == "starting" && inStartPeriod) {
            health.FailingStreak += 1
            if health.FailingStreak >= retries { health.Status = "unhealthy" }
        }
    }

    private static func healthProbe(guest: GuestClient, containerID: String, config: ContainerConfig, command: [String], timeout: UInt64) async throws -> (Int, String) {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            group.addTask {
                let stream = try await guest.openStream(StreamOp.exec, [
                    "exec": .string(IDs.random64()), "container": .string(containerID), "argv": .strings(command),
                    "env": .strings(config.Env ?? []), "cwd": .string(config.WorkingDir),
                    "user": .string(config.User), "tty": .bool(false), "stdin": .bool(false), "privileged": .bool(false)])
                return try await withTaskCancellationHandler {
                    defer { stream.close() }
                    try Task.checkCancellation()
                    var output = Data()
                    while let frame = try await stream.nextFrame() {
                        if frame.kind == .stdout || frame.kind == .stderr {
                            output.append(frame.payload.prefix(max(0, 4096 - output.count)))
                        }
                        if let code = frame.exitCode { return (Int(code), String(decoding: output, as: UTF8.self)) }
                    }
                    try Task.checkCancellation()
                    return (-1, "health check stream closed before exit")
                } onCancel: { stream.close() }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                return (-1, "health check timed out")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
