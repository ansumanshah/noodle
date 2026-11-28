import Foundation
import Testing
@testable import NoodleEngine

@Suite struct HostSharingTests {
    @Test func volumeNoCopyOptionsReachGuest() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = Engine(paths: NoodlePaths(root: base))
        let data = Data(#"{"Binds":["named:/one:nocopy"],"Mounts":[{"Type":"volume","Source":"other","Target":"/two","VolumeOptions":{"NoCopy":true}}]}"#.utf8)
        let host = try JSONDecoder().decode(HostConfig.self, from: data)
        let resolved = try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        #expect(resolved.guest.count == 2)
        #expect(resolved.guest.allSatisfy { $0.noCopy == true })
    }

    @Test func directoryBindsResolveAliasesAndRejectFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("directory")
        let alias = base.appendingPathComponent("alias")
        let file = base.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        try Data().write(to: file)
        let engine = Engine(paths: NoodlePaths(root: base.appendingPathComponent("noodle")))
        var host = HostConfig()
        host.Binds = ["\(alias.path):/data:ro"]
        let resolved = try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        #expect(resolved.guest.count == 1)
        #expect(resolved.guest[0].source == dir.resolvingSymlinksInPath().path)
        #expect(resolved.guest[0].readOnly)
        host.Binds = ["\(file.path):/data:ro"]
        await #expect(throws: EngineError.self) {
            try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        }
        await #expect(throws: EngineError.self) { try await engine.sharedHostPath("relative/path") }
    }

    @Test func fileBindsRequireCurrentCanonicalApproval() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let allowed = base.appendingPathComponent("allowed")
        let outside = base.appendingPathComponent("allowed-sibling")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = allowed.appendingPathComponent("file")
        let secret = outside.appendingPathComponent("secret")
        try Data().write(to: file)
        try Data().write(to: secret)
        let alias = allowed.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secret)
        let paths = NoodlePaths(root: base.appendingPathComponent("noodle"))
        let engine = Engine(paths: paths)
        var host = HostConfig(); host.Binds = ["\(file.path):/data:ro"]
        await #expect(throws: EngineError.self) { try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: []) }
        var settings = VMSettings.defaults()
        settings.approvedDirectories = [try VMSettings.canonicalDirectory(allowed.path)]
        try settings.save(paths: paths)
        let result = try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: [])
        #expect(result.guest[0].readOnly)
        host.Binds = ["\(alias.path):/data"]
        await #expect(throws: EngineError.self) { try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: []) }
        host.Binds = ["\(secret.path):/data"]
        await #expect(throws: EngineError.self) { try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: []) }
        try await engine.updateVMSettings(cpus: 2)
        #expect(VMSettings.load(paths: paths).approvedDirectories == settings.approvedDirectories)
        settings.approvedDirectories = []
        try settings.save(paths: paths)
        await #expect(throws: EngineError.self) { try await engine.validateBindSource(file.resolvingSymlinksInPath().path) }
    }
}
