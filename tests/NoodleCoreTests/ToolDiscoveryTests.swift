import Foundation
import Testing
@testable import NoodleCore

@Suite struct ToolDiscoveryTests {
    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func script(_ dir: URL, _ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func discovery(_ root: URL, path: String) -> ToolDiscovery {
        ToolDiscovery(env: ["PATH": path, "HOME": root.path + "/home", "DOCKER_CONFIG": root.path + "/cfg"],
                      paths: NoodlePaths(root: root.appendingPathComponent("noodle")))
    }

    @Test func versionFloors() {
        #expect(ToolDiscovery.versionOK("docker", output: "Docker version 20.10.0, build x"))
        #expect(!ToolDiscovery.versionOK("docker", output: "Docker version 19.03.15, build x"))
        #expect(ToolDiscovery.versionOK("docker-compose", output: "Docker Compose version v2.40.0"))
        #expect(!ToolDiscovery.versionOK("docker-compose", output: "docker-compose version 1.29.2"))
        #expect(ToolDiscovery.versionOK("docker-buildx", output: "github.com/docker/buildx v0.10.0 abc"))
        #expect(!ToolDiscovery.versionOK("docker-buildx", output: "github.com/docker/buildx v0.9.1 abc"))
        #expect(!ToolDiscovery.versionOK("docker", output: "something else 99.0"))
    }

    @Test func compatibleToolsAreAcceptedAndOldOrBrokenOnesAreNot() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let good = try script(bin, "docker", "echo 'Docker version 27.0.1, build abc'")
        let old = try script(bin, "old-docker", "echo 'Docker version 19.3.0, build abc'")
        let broken = try script(bin, "broken-docker", "echo 'Docker version 27.0.1'; exit 1")
        let d = discovery(root, path: bin.path)
        #expect(d.compatible(good, name: "docker"))
        #expect(!d.compatible(old, name: "docker"))
        #expect(!d.compatible(broken, name: "docker"))
        #expect(!d.compatible(bin.path + "/missing", name: "docker"))
        #expect(d.docker() == good)
    }

    @Test func managedFolderIsExcludedFromExternalLookup() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = discovery(root, path: "/usr/bin")
        let managed = Tools.directory(d.paths).path
        #expect(d.candidates("docker", includeManaged: true).contains(managed + "/docker"))
        #expect(!d.candidates("docker", includeManaged: false).contains(managed + "/docker"))
        #expect(!d.candidates("docker-compose", includeManaged: false).contains(Tools.pluginDirectory(d.paths).path + "/docker-compose"))
        // A working copy in the managed folder is still used when nothing else exists.
        try FileManager.default.createDirectory(atPath: managed, withIntermediateDirectories: true)
        let own = try script(URL(fileURLWithPath: managed), "docker", "echo 'Docker version 29.9.3'")
        #expect(d.compatible(own, name: "docker"))
    }

    @Test func desktopPluginCandidatesFollowExistingChoices() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = discovery(root, path: root.path + "/bin")
        for name in ["docker-compose", "docker-buildx"] {
            let candidates = d.candidates(name, includeManaged: true)
            let managed = try #require(candidates.firstIndex(of: Tools.pluginDirectory(d.paths).path + "/" + name))
            let system = try #require(candidates.firstIndex(of: "/usr/local/cli-plugins/" + name))
            let desktop = try #require(candidates.firstIndex(of: "/Applications/Docker.app/Contents/Resources/cli-plugins/" + name))
            #expect(managed < system && system < desktop)
            #expect(d.candidates(name, includeManaged: false).contains(candidates[desktop]))
        }
        #expect(!d.candidates("docker", includeManaged: true).contains("/usr/local/cli-plugins/docker"))
    }

    @Test func pluginMustWorkThroughDocker() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let docker = try script(bin, "docker", """
        case "$1" in
          --version) echo 'Docker version 27.0.1, build abc' ;;
          compose) [ -x "$DOCKER_CONFIG/cli-plugins/docker-compose" ] && exec "$DOCKER_CONFIG/cli-plugins/docker-compose" version || exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        let plugin = try script(bin, "docker-compose", "echo 'Docker Compose version v2.40.0'")
        let d = discovery(root, path: bin.path)
        #expect(d.compatible(plugin, name: "docker-compose"))
        #expect(!d.plugin("docker-compose", worksUnder: docker))
        let cfg = root.appendingPathComponent("cfg/cli-plugins")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cfg.appendingPathComponent("docker-compose"), withDestinationURL: URL(fileURLWithPath: plugin))
        #expect(d.plugin("docker-compose", worksUnder: docker))
    }
}
