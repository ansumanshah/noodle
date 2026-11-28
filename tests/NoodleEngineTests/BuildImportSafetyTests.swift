import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

@Suite struct BuildImportSafetyTests {
    @Test func builderVerifiesConfigAndUsesOnlyRequestedTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore(paths: NoodlePaths(root: root))
        var old = ImageConfig(); old.created = "2026-01-01T00:00:00Z"
        let existing = try await store.register(config: old, layers: [], tags: ["keep:latest", "target:latest"])
        var incoming = ImageConfig(); incoming.created = "2026-02-01T00:00:00Z"
        let config = try JSONEncoder().encode(incoming)
        let digest = Digest.sha256(config)
        let archive = root.appendingPathComponent("build.tar")
        let writer = try TarWriter(url: archive)
        try writer.addFile("config.json", data: config)
        let manifest: [[String: Any]] = [["Config": "config.json", "RepoTags": ["keep:latest", "evil:latest"], "Layers": [String]()]]
        try writer.addFile("manifest.json", data: JSONSerialization.data(withJSONObject: manifest))
        try writer.finish()
        let gz = root.appendingPathComponent("build.tar.gz")
        _ = try Gzip.compress(archive, to: gz)
        for invalid in [String(digest.dropFirst(7)), digest.uppercased(), "sha256:short"] {
            await #expect(throws: (any Error).self) { _ = try await store.load(from: archive, buildTags: ["target:latest"], expectedBuildConfig: invalid) }
        }
        await #expect(throws: (any Error).self) { _ = try await store.load(from: archive, buildTags: ["target:latest"], expectedBuildConfig: Digest.sha256(Data("wrong".utf8))) }
        await #expect(throws: (any Error).self) { _ = try await store.load(from: gz, buildTags: ["target:latest"], expectedBuildConfig: digest) }
        await #expect(throws: (any Error).self) { _ = try await store.load(from: archive, expectedBuildConfig: digest) }
        for (name, entries) in [("empty", [[String: Any]]()), ("multiple", manifest + manifest)] {
            let badArchive = root.appendingPathComponent("\(name).tar")
            let badWriter = try TarWriter(url: badArchive)
            try badWriter.addFile("manifest.json", data: JSONSerialization.data(withJSONObject: entries))
            try badWriter.finish()
            await #expect(throws: (any Error).self) { _ = try await store.load(from: badArchive, buildTags: [], expectedBuildConfig: digest) }
        }
        #expect(try await store.resolve("target:latest").id == existing.id)
        #expect(try await store.resolve("keep:latest").id == existing.id)
        #expect(await store.all().count == 1)
        let loaded = try await store.load(from: archive, buildTags: ["target:latest"], expectedBuildConfig: digest)
        #expect(loaded.first?.id == digest)
        #expect(try await store.resolve("target:latest").id == digest)
        #expect(try await store.resolve("keep:latest").id == existing.id)
        await #expect(throws: ImageError.self) { _ = try await store.resolve("evil:latest") }
        _ = try await store.load(from: archive, buildTags: [], expectedBuildConfig: digest)
        await #expect(throws: ImageError.self) { _ = try await store.resolve("evil:latest") }
        let restored = ImageStore(paths: NoodlePaths(root: root))
        #expect(try await restored.resolve("target:latest").id == digest)
        #expect(try await restored.resolve("keep:latest").id == existing.id)
    }
}
