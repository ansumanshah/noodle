import Foundation
import Testing
@testable import NoodleEngine

@Suite struct DockerSocketBindTests {
    private func resolve(_ bind: String, root: URL) async throws -> [GuestMount] {
        let engine = Engine(paths: NoodlePaths(root: root))
        var host = HostConfig()
        host.Binds = [bind]
        return try await engine.resolveMounts(hc: host, cfg: ContainerConfig(), imageVolumes: []).guest
    }

    @Test func ownSocketAndConventionalPathBecomeDockerMounts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let own = NoodlePaths(root: base).socket.path
        for source in [own, "/var/run/docker.sock"] {
            let mounts = try await resolve("\(source):/var/run/docker.sock", root: base)
            #expect(mounts.map(\.kind) == ["docker"])
            #expect(mounts.first?.target == "/var/run/docker.sock")
        }
    }

    @Test func otherSocketsAreStillRefused() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        await #expect(throws: (any Error).self) { _ = try await resolve("/var/run/other.sock:/x", root: base) }
    }

    @Test func runSockAndSymlinkToTheDaemonSocketAreDockerMounts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let own = NoodlePaths(root: base).socket
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: own)  // stands in for the socket so the link resolves
        let link = base.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        for source in ["/run/docker.sock", link.path] {
            #expect(try await resolve("\(source):/s", root: base).map(\.kind) == ["docker"])
        }
    }

    @Test func dotDotAndTrailingSlashSpellingsAreNotDockerMounts() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let own = NoodlePaths(root: base).socket.path
        for source in ["\(own)/..", "\(own)/", "/var/run/docker.sock/", "/var/run/docker.sock/.."] {
            let kinds = (try? await resolve("\(source):/s", root: base).map(\.kind)) ?? []
            #expect(!kinds.contains("docker"), "\(source)")
        }
    }

    @Test func aRegularFileNamedDockerSockStaysAPlainBind() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("docker.sock")
        try Data().write(to: file)
        // Not approved, so the plain file bind is refused as such; it never turns into a docker mount.
        await #expect(throws: (any Error).self) { _ = try await resolve("\(file.path):/s", root: base) }
    }

    @Test func privilegedAndUnconfinedContainersRefuseTheSocket() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        for hostConfig in [#""Privileged":true"#, #""SecurityOpt":["seccomp=unconfined"]"#] {
            let body = #"{"Image":"tiny","HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock"],"# + hostConfig + "}}"
            let request = try JSONDecoder().decode(ContainerCreateRequest.self, from: Data(body.utf8))
            do { _ = try await engine.createContainer(name: nil, request: request); Issue.record("created") }
            catch { #expect("\(error)".contains("Docker socket")) }
        }
        await engine.shutdown()
    }

    @Test func volumeNamesAllowUpTo255Characters() throws {
        try Engine.validateVolumeName("act-smoke-hosted-" + String(repeating: "a", count: 64))
        try Engine.validateVolumeName("v" + String(repeating: "a", count: 254))
        #expect(throws: (any Error).self) { try Engine.validateVolumeName("v" + String(repeating: "a", count: 255)) }
    }
}
