import Foundation
import Testing
@testable import NoodleApp

@MainActor struct SetupOnboardingTests {
    private func prepared() async -> (SetupFlow, ScriptedSetupBackend) {
        let backend = ScriptedSetupBackend()
        backend.detection.tools = SetupPreview.tools(missing: [])
        let flow = SetupFlow(backend: backend)
        await flow.detectAll()
        return (flow, backend)
    }

    @Test func composeWorksAfterFirstContainer() async {
        let (flow, backend) = await prepared()
        #expect(flow.composeCheck == .idle)
        await flow.install()
        #expect(flow.stage == .done && flow.composeCheck == .available)
        #expect(backend.calls.suffix(3) == ["pull", "run", "compose"])
        #expect(flow.composeCommand == "docker compose up")
        flow.useDefault = false
        #expect(flow.composeCommand == "docker --context noodle compose up")
        flow.useDefault = true
        flow.detection?.dockerOverride = "DOCKER_HOST"
        #expect(flow.composeCommand == "docker --context noodle compose up")
    }

    @Test func composeFailureLeavesDoneAvailable() async {
        let (flow, backend) = await prepared()
        backend.composeResult = .init(code: 1, output: "docker: unknown command: compose")
        await flow.install()
        #expect(flow.stage == .done && !flow.busy && flow.problem == nil)
        #expect(flow.composeCheck == .failed(backend.composeResult.output))
        #expect(flow.transcript == SetupFlow.greeting)
    }

    @Test func slowComposeDoesNotBlockDoneAndClosingCancelsIt() async throws {
        let (flow, backend) = await prepared()
        backend.hold.insert("compose")
        flow.startInstall()
        defer { flow.cancel() }
        try await SetupChecks.until("Compose checking") { flow.composeCheck == .checking }
        #expect(flow.stage == .done && !flow.busy)
        flow.abandon()
        await flow.task?.value
        #expect(flow.stage == .done && flow.composeCheck == .checking)
        #expect(flow.task?.isCancelled == true)
    }

    @Test func failedFirstContainerDoesNotProbeCompose() async {
        let (flow, backend) = await prepared()
        backend.containerResult = .init(code: 1, output: "failed")
        await flow.install()
        #expect(flow.stage == .failed && !backend.calls.contains("compose"))
        #expect(flow.composeCheck == .idle)
    }

    @Test func applyWaitNamesSocketThenDockerVersion() async throws {
        let (flow, backend) = await prepared()
        backend.hold = ["socket", "docker-version"]
        flow.startInstall()
        defer { flow.cancel() }
        try await SetupChecks.until("socket wait") { flow.applyWait == .socket }
        #expect(flow.stage == .install && flow.applyStartedAt != nil)
        backend.hold.remove("socket")
        try await SetupChecks.until("docker version wait") { flow.applyWait == .dockerVersion }
        #expect(flow.stage == .install)
        backend.hold.remove("docker-version")
        await flow.task?.value
        #expect(flow.stage == .done && flow.applyStartedAt == nil)
    }

    @Test func elapsedAppearsOnlyAfterTenSeconds() {
        let start = Date(timeIntervalSince1970: 100)
        #expect(SetupApplyWait.socket.elapsed(since: start, at: start.addingTimeInterval(9.9)) == nil)
        #expect(SetupApplyWait.socket.elapsed(since: start, at: start.addingTimeInterval(10))
                == "10 s elapsed · Waiting for Noodle’s Docker socket")
        #expect(SetupApplyWait.dockerVersion.elapsed(since: start, at: start.addingTimeInterval(24))
                == "24 s elapsed · Waiting for docker version")
    }

    @Test func reentrySurvivesPartialInstallAndStaysQuietAfterCompletion() {
        let connection = ConnectionModel()
        connection.setupDone = false
        connection.setupCompleted = nil
        #expect(connection.needsSetup)
        connection.setupCompleted = false // Not Now
        #expect(connection.needsSetup)
        connection.setupDone = true // Apply finished, first-container check was skipped
        #expect(connection.needsSetup)
        connection.setupCompleted = true // Done
        #expect(!connection.needsSetup)
        connection.setupCompleted = nil // Existing installation
        #expect(!connection.needsSetup)
        connection.setupDone = false // Uninstalled
        #expect(connection.needsSetup)
    }
}
