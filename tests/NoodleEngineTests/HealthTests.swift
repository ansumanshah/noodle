import Foundation
import Testing
@testable import NoodleEngine

@Suite struct HealthTests {
    @Test func commandForms() {
        var config = HealthConfig()
        config.Test = ["CMD", "test", "-f", "/tmp/ok"]
        #expect(Engine.healthCommand(config) == ["test", "-f", "/tmp/ok"])
        config.Test = ["CMD-SHELL", "echo hello"]
        #expect(Engine.healthCommand(config) == ["/bin/sh", "-c", "echo hello"])
        config.Test = ["NONE"]
        #expect(Engine.healthCommand(config) == nil)
        config.Test = ["CMD"]
        #expect(Engine.healthCommand(config) == nil)
    }

    @Test func imageStartIntervalRoundTrips() async throws {
        var config = ContainerConfig()
        var health = HealthConfig()
        health.Test = ["CMD", "true"]
        health.StartInterval = 2_000_000_000
        config.Healthcheck = health
        let imageConfig = Engine.runtimeConfig(from: config)
        let decoded = try JSONDecoder().decode(ImageConfig.RuntimeConfig.self, from: JSONEncoder().encode(imageConfig))
        let engine = Engine(paths: NoodlePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let result = await engine.containerConfig(from: decoded)
        #expect(result.Healthcheck?.StartInterval == health.StartInterval)
    }

    @Test func graceRetriesRecoveryAndBoundedLog() {
        var health = HealthState()
        func entry(_ code: Int) -> HealthState.LogEntry {
            HealthState.LogEntry(Start: "start", End: "end", ExitCode: code, Output: "output")
        }
        Engine.applyHealthResult(&health, entry: entry(1), retries: 2, inStartPeriod: true)
        #expect(health.Status == "starting")
        #expect(health.FailingStreak == 0)
        Engine.applyHealthResult(&health, entry: entry(1), retries: 2, inStartPeriod: false)
        #expect(health.Status == "starting")
        Engine.applyHealthResult(&health, entry: entry(1), retries: 2, inStartPeriod: false)
        #expect(health.Status == "unhealthy")
        Engine.applyHealthResult(&health, entry: entry(0), retries: 2, inStartPeriod: true)
        #expect(health.Status == "healthy")
        #expect(health.FailingStreak == 0)
        Engine.applyHealthResult(&health, entry: entry(1), retries: 2, inStartPeriod: true)
        #expect(health.FailingStreak == 1)
        Engine.applyHealthResult(&health, entry: entry(1), retries: 2, inStartPeriod: true)
        #expect(health.Status == "unhealthy")
        #expect(health.Log.count == 5)
    }

    @Test func disabledChecksDoNotScheduleAndStoppingCancels() async {
        let engine = Engine(paths: NoodlePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var config = ContainerConfig()
        var health = HealthConfig()
        health.Test = ["NONE"]
        config.Healthcheck = health
        let id = "health-test"
        await engine.setTestContainer(id, config: config)
        await engine.startHealth(id)
        #expect(await engine.healthTasks.isEmpty)
        health.Test = ["CMD", "true"]
        config.Healthcheck = health
        await engine.setTestContainer(id, config: config)
        await engine.startHealth(id)
        #expect(await engine.healthTasks[id] != nil)
        #expect(await engine.containers[id]?.health?.Status == "starting")
        await engine.stopHealth(id)
        #expect(await engine.healthTasks.isEmpty)
    }

    /// A paused container must not keep a health timer waking the daemon; resuming keeps the health state.
    @Test(.timeLimit(.minutes(1))) func pausedMonitorEndsAndResumeKeepsState() async throws {
        let engine = Engine(paths: NoodlePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var config = ContainerConfig()
        var health = HealthConfig()
        health.Test = ["CMD", "true"]
        health.Interval = 1_000_000
        health.Timeout = 1_000_000
        config.Healthcheck = health
        let id = "health-pause"
        await engine.setTestContainer(id, config: config)
        await engine.startHealth(id)
        let entry = await engine.healthTasks[id]
        let task = try #require(entry?.task)
        await engine.setTestStatus(id, .paused)
        await task.value
        await engine.setTestStatus(id, .running)
        await engine.setTestHealth(id, "healthy")
        await engine.startHealth(id, resume: true)
        #expect(await engine.containers[id]?.health?.Status == "healthy")
        #expect(await engine.healthTasks[id] != nil)
        await engine.stopHealth(id)
    }
}

private extension Engine {
    func setTestStatus(_ id: String, _ status: ContainerStatus) { containers[id]?.status = status }
    func setTestHealth(_ id: String, _ status: String) { containers[id]?.health?.Status = status }

    func setTestContainer(_ id: String, config: ContainerConfig) {
        var container = ContainerRecord(id: id, name: id, created: Date(), image: "test", imageID: "test", config: config, hostConfig: HostConfig())
        container.status = .running
        containers[id] = container
    }
}
