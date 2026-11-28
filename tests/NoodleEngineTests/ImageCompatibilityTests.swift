import Foundation
import Testing
@testable import NoodleEngine
@testable import NoodleImages

@Suite struct ImageCompatibilityTests {
    @Test func taggedImportsAndTagsPreserveRegistryPorts() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        let tar = paths.root.appendingPathComponent("rootfs.tar")
        try paths.ensureDirectories()
        let writer = try TarWriter(url: tar)
        try writer.addFile("hello", data: Data("world".utf8))
        try writer.finish()
        let imported = try await engine.importImage(from: tar, repo: "e2e/imp:1")
        #expect(try await engine.imageStore.resolve("e2e/imp:1").id == imported.id)
        _ = try await engine.importImage(from: tar, repo: "localhost:5000/team/app:old", tag: "new")
        #expect(try await engine.imageStore.resolve("localhost:5000/team/app:new").repoTags.contains("localhost:5000/team/app:new"))
        try await engine.tagImage("e2e/imp:1", repo: "localhost:5000/team/copy:one")
        try await engine.tagImage("e2e/imp:1", repo: "localhost:5000/team/copy:one", tag: "two")
        #expect(try await engine.imageStore.resolve("localhost:5000/team/copy:one").id == imported.id)
        #expect(try await engine.imageStore.resolve("localhost:5000/team/copy:two").id == imported.id)
        #expect(try Engine.imageTag(repo: "localhost:5000/team/plain", tag: nil) == "localhost:5000/team/plain:latest")
        #expect(throws: EngineError.self) { try Engine.imageTag(repo: "e2e/imp:1", tag: "bad!") }
    }

    @Test func createRequiresRequestedImagePlatform() async throws {
        let paths = tempPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        _ = try await makeImage(engine)
        var request = ContainerCreateRequest(); request.config.Image = "tiny"
        for platform in ["linux/amd64", "windows/arm64", "linux/arm64/v7"] {
            do {
                _ = try await engine.createContainer(name: nil, request: request, platform: platform)
                Issue.record("created with incompatible platform \\(platform)")
            } catch let error as EngineError { #expect(error.httpStatus == 404) }
        }
        for platform in ["", "linux/", "/amd64", "linux//amd64", "linux/amd64/invalid/extra"] {
            do {
                _ = try await engine.createContainer(name: nil, request: request, platform: platform)
                Issue.record("accepted invalid platform \\(platform)")
            } catch let error as EngineError { #expect(error.httpStatus == 400) }
        }
        _ = try await engine.createContainer(name: "armmatch", request: request, platform: "linux/aarch64")
        _ = try await engine.createContainer(name: "legacy", request: request)
        var amd = ImageConfig(); amd.os = "linux"; amd.architecture = "amd64"
        var config = ImageConfig.RuntimeConfig(); config.cmd = ["sh"]; amd.config = config
        _ = try await engine.imageStore.register(config: amd, layers: [], tags: ["amd:latest"])
        request.config.Image = "amd"
        _ = try await engine.createContainer(name: "amdmatch", request: request, platform: "linux/x86_64")
    }
}
