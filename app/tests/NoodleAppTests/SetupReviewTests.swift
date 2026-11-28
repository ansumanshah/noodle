import AppKit
import Foundation
import Testing
@testable import NoodleApp

@MainActor struct SetupReviewTests {
    init() { _ = RenderHarness.env }

    @Test func skippedApplyStillBlocksSetupAndUninstallUntilCommandExits() async throws {
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: true)
        let flow = SetupFlow(backend: ScriptedSetupBackend())
        var release = false
        flow.stage = .install
        flow.applyingChoices = true
        flow.launch {
            _ = await env.runSetup(["setup"]) { _ in
                while !release { try? await Task.sleep(for: .milliseconds(5)) }
                return .init(code: 0, output: "applied")
            }
        }
        defer { release = true }
        try await SetupChecks.until("shared setup mutation") { env.nav.setupMutationRunning }
        flow.abandon() // Skip for Now leaves the atomic CLI command running.
        env.nav.requestSetup()
        #expect(!env.nav.showSetup)
        let uninstall = UninstallFlow { _ in .init(code: 0, output: "must not run") }
        await env.uninstall(using: uninstall)
        #expect(uninstall.result == nil && env.nav.setupMutationRunning)
        let overlapping = await env.runSetup(["setup"]) { _ in .init(code: 0, output: "must not run") }
        #expect(overlapping.code != 0)
        release = true
        await flow.task?.value
        #expect(!env.nav.setupMutationRunning)
        env.nav.requestSetup()
        #expect(env.nav.showSetup)
    }

    @Test func settingsOnlyUninstallBlocksHandoffQuitAndDaemonStart() async throws {
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: false)
        env.connection.phase = .down("fixture")
        let flow = UninstallFlow { _ in
            try? await Task.sleep(for: .milliseconds(150))
            return .init(code: 1, output: "fixture failure")
        }
        let work = Task { await env.uninstall(using: flow) }
        try await SetupChecks.until("Settings-only uninstall") { env.nav.uninstallRunning }
        #expect(!env.nav.canChangeInstallation)
        var opened = false
        env.openMain = { opened = true }
        env.showMainWindow()
        await env.startDaemon()
        #expect(!opened && env.connection.transition == nil)
        #expect(AppDelegate(environment: env).applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        await work.value
        #expect(!env.nav.uninstallFinished && !env.nav.uninstallRunning)
        #expect(env.nav.canChangeInstallation && !env.nav.installationBusy)
    }

    @Test func failureWithoutMainWindowKeepsEventStreamStopped() async {
        _ = NSApplication.shared
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: false)
        env.connection.phase = .down("fixture")
        let flow = UninstallFlow { _ in .init(code: 1, output: "retry") }
        await env.uninstall(using: flow)
        #expect(!env.nav.uninstallRunning && !env.nav.uninstallFinished)
        #expect(!env.sync.windowVisible)
    }

    @Test func completedInstallationStaysCompletedAfterReopenAndNotNow() {
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: true)
        env.connection.setupDone = true
        env.connection.setupCompleted = true
        env.nav.requestSetup()
        let previouslyCompleted = !env.connection.needsSetup
        env.finishSetup(finished: false, previouslyCompleted: previouslyCompleted)
        #expect(!env.connection.needsSetup)
        env.connection.setupCompleted = nil // Installations that predate the completion receipt.
        env.finishSetup(finished: false, previouslyCompleted: !env.connection.needsSetup)
        #expect(!env.connection.needsSetup)
    }

    @Test func foreignSelectedContextIsNeverRestored() throws {
        func metadata(description: String, socket: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["Name": "noodle", "Metadata": ["Description": description],
                                                        "Endpoints": ["docker": ["Host": socket]]])
        }
        let owned = try metadata(description: "Noodle", socket: "unix:///own.sock")
        let foreign = try metadata(description: "Noodle", socket: "unix:///other.sock")
        #expect(UninstallNoodle.ownsContext(owned, socket: "/own.sock", recordedEndpoint: nil))
        #expect(!UninstallNoodle.ownsContext(foreign, socket: "/own.sock", recordedEndpoint: nil))
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "desktop-linux", available: ["desktop-linux"],
                                               owned: UninstallNoodle.ownsContext(foreign, socket: "/own.sock", recordedEndpoint: nil)) == nil)
        #expect(UninstallNoodle.ownsContext(foreign, socket: "/own.sock", recordedEndpoint: "unix:///other.sock"))
        let renamed = try metadata(description: "Other runtime", socket: "unix:///own.sock")
        #expect(!UninstallNoodle.ownsContext(renamed, socket: "/own.sock", recordedEndpoint: nil))
    }

    @Test func deletionInvocationFinishesAfterPresentingTaskIsCancelled() async throws {
        let directory = try scratchDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("noodle")
        try "#!/bin/sh\nsleep 0.15\nprintf 'deletion-finished'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let task = Task { await UninstallNoodle.invoke(executable: cli, arguments: ["uninstall", "--delete-data", "--yes"]) }
        task.cancel()
        let result = await task.value
        #expect(result.code == 0 && result.output == "deletion-finished")
    }

    @Test func occupiedBrokenComposePluginShowsProbeErrorAndRepairPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-occupied-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("cli-plugins"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent("cli-plugins/docker-compose")
        try Data("broken plugin".utf8).write(to: plugin)
        let docker = directory.appendingPathComponent("docker")
        try "#!/bin/sh\necho 'compose: exec format error' >&2\nexit 1\n".write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: docker.path)
        let result = await SetupComposeCheck.verify(docker: docker.path, configDirectory: directory.path)
        #expect(result.code == 1 && result.output.contains("exec format error"))
        #expect(result.output.contains(plugin.path) && result.output.contains("Repair or move this plugin"))
        #expect(try Data(contentsOf: plugin) == Data("broken plugin".utf8))
    }

    @Test func dataPathResolvesSymlinksBeforeItIsShown() throws {
        let directory = try scratchDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        #expect(UninstallNoodle.resolvedDataPath(alias) == directory.resolvingSymlinksInPath().path)
    }
}
