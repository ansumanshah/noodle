import Foundation
import Testing
@testable import NoodleCore

@Suite struct ModelToolPluginTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-model-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func metadataMatchesUpstreamCLI() throws {
        let text = try #require(LazyToolPlugin.metadata("docker-model"))
        let fields = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
        #expect(fields == ["SchemaVersion": "0.1.0", "Vendor": "Docker Inc.",
                           "Version": "v" + Tools.modelVersion, "ShortDescription": "Docker Model Runner"])
        #expect(SetupTool(name: "docker-model", path: nil).title == "Model Runner")
    }

    @Test func modelPinMatchesVerifiedOfficialDesktopBinary() throws {
        let pin = try #require(Tools.pins.first { $0.name == "docker-model" })
        #expect(pin.kind == .plugin)
        #expect(pin.version == "1.2.9")
        #expect(pin.sha256 == "347a6bdf2edc4abcd2ce9d738122e3ed9d800c089e83aa6affe4e30809dced8a")
        #expect(pin.upstream == "https://registry-1.docker.io/v2/docker/docker-model-cli-desktop-module")
        #expect(pin.url(mirror: "file:///mirror/") == "file:///mirror/docker-model-v1.2.9.darwin-arm64")
    }

    @Test func modelRetainsItsStubAndForeignNamesArePreserved() {
        #expect(LazyToolPlugin.retainsStub("docker-model"))
        #expect(!LazyToolPlugin.retainsStub("docker-compose"))
        #expect(!LazyToolPlugin.retainsStub("docker-buildx"))
        #expect(Tools.linksToCreate(existing: []).contains("docker-model"))
        #expect(!Tools.linksToCreate(existing: ["docker-model"]).contains("docker-model"))
        #expect(Tools.pluginNames.filter { $0 == "docker-model" }.count == 1)
    }

    @Test func versionUsesClientRatherThanServer() {
        let output = "Client:\n Version:    v1.2.9\n OS/Arch:    darwin/arm64\n\nServer:\n Version:    (not reachable)\n"
        #expect(ToolDiscovery.versionOK("docker-model", output: output))
        #expect(!ToolDiscovery.versionOK("docker-model", output: output.replacingOccurrences(of: "v1.2.9", with: "v0.2.9")))
        #expect(!ToolDiscovery.versionOK("docker-model", output: "Docker Compose version v2.40.0"))
        #expect(!ToolDiscovery.versionOK("docker-model", output: "Server:\n Version: v1.2.9"))
    }

    @Test func externalDiscoveryUsesMetadataWithoutContactingRunner() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("docker-model")
        let metadata = try #require(LazyToolPlugin.metadata("docker-model"))
        try "#!/bin/sh\n[ \"$1\" = docker-cli-plugin-metadata ] || exit 97\nprintf '%s\\n' '\(metadata)'\n"
            .write(to: plugin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugin.path)
        let discovery = ToolDiscovery(env: ["HOME": root.path, "PATH": root.path], paths: NoodlePaths(root: root))
        #expect(discovery.compatible(plugin.path, name: "docker-model"))
        #expect(discovery.candidates("docker-model", includeManaged: false)
            .contains("/Applications/Docker.app/Contents/Resources/cli-plugins/docker-model"))
        try "#!/bin/sh\necho '{\"SchemaVersion\":\"0.1.0\",\"Vendor\":\"Other\",\"Version\":\"v1.2.9\",\"ShortDescription\":\"Docker Model Runner\"}'\n"
            .write(to: plugin, atomically: true, encoding: .utf8)
        #expect(!discovery.compatible(plugin.path, name: "docker-model"))
    }

    @Test func readyStubDoesNotExecuteCLIOrDockerAndRejectsModifiedCLI() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let paths = NoodlePaths(root: root.appendingPathComponent("noodle"))
        let cli = root.appendingPathComponent("home/.local/bin/noodle")
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 97\n".write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let stub = LazyToolPlugin.directory(paths).appendingPathComponent("docker-model")
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LazyToolPlugin.script("docker-model", cli: cli, paths: paths).write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let config = root.appendingPathComponent("config")
        let link = config.appendingPathComponent("cli-plugins/docker-model")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: stub)
        let receipt = ["link:" + link.path: stub.path, "cli-sha256": try Digest.sha256(file: cli)]
        try JSONEncoder().encode(receipt).write(to: paths.root.appendingPathComponent("setup.json"))
        let discovery = ToolDiscovery(env: ["HOME": root.path + "/home", "DOCKER_CONFIG": config.path], paths: paths)
        #expect(discovery.lazyPlugin("docker-model") == link.path)
        #expect(discovery.plugin("docker-model", worksUnder: "/missing/docker"))
        #expect(discovery.compatible(link.path, name: "docker-model"))
        // An upstream binary arriving in the cache must not invalidate the retained stub.
        let binary = Tools.pluginDirectory(paths).appendingPathComponent("docker-model")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "upstream remains separate".write(to: binary, atomically: true, encoding: .utf8)
        #expect(discovery.lazyPlugin("docker-model") == link.path)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == stub.path)
        try "#!/bin/sh\nexit 98\n".write(to: cli, atomically: true, encoding: .utf8)
        #expect(discovery.lazyPlugin("docker-model") == nil)
        #expect(!discovery.compatible(link.path, name: "docker-model"))
    }
}
