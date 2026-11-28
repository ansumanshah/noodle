import Foundation
import Testing
import NoodleCore
@testable import NoodleApp

@Suite @MainActor struct SetupLazyToolsTests {
    @Test func firstRunDownloadsOnlyDocker() async {
        let backend = ScriptedSetupBackend()
        let flow = SetupFlow(backend: backend)
        await flow.detectAll()
        #expect(flow.downloadsNow)
        #expect(!flow.terminalCommand.contains("--tools"))
        await flow.download()
        #expect(backend.installArgs == ["tools", "install", "--no-link", "docker"])
        #expect(flow.stage == .engine)
    }

    @Test func missingPluginsDoNotDownloadDuringSetup() async {
        let backend = ScriptedSetupBackend()
        backend.detection.tools = [SetupTool(name: "docker", path: "/fixture/docker"),
                                   SetupTool(name: "docker-compose", path: nil), SetupTool(name: "docker-buildx", path: nil)]
        let flow = SetupFlow(backend: backend)
        await flow.detectAll()
        #expect(!flow.downloadsNow)
        #expect(!backend.calls.contains("sizes"))
        flow.continueFromTools()
        #expect(flow.stage == .engine)
        #expect(!backend.calls.contains("install"))
    }

    @Test func versionProbeDoesNotInvokeAStubFoundOutsideTheCurrentConfig() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("noodle")
        try "#!/bin/sh\necho 'Docker Compose version v5.7.1'\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("docker-compose")
        try LazyToolPlugin.script("docker-compose", cli: cli, paths: NoodlePaths(root: root))
            .write(to: stub, atomically: true, encoding: .utf8)
        for file in [cli, stub] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        #expect(SetupProbe.version(stub.path, ["version"]) == nil)
    }
}
