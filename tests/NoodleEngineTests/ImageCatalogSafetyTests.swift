import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

@Suite struct ImageCatalogSafetyTests {
    @Test func corruptCatalogPreservesCatalogAndBlobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths.resolve(environment: ["NOODLE_HOME": root.path])
        try paths.ensureDirectories()
        let broken = Data("{invalid".utf8)
        try broken.write(to: paths.imagesFile)
        let store = ImageStore(paths: paths)
        let digest = try store.blobs.put(Data("keep this blob".utf8))
        await #expect(throws: (any Error).self) { try await store.validateCatalog() }
        await #expect(throws: (any Error).self) { _ = try await store.prune(danglingOnly: false, inUse: []) }
        #expect(await store.collectBlobs() == 0)
        #expect(store.blobs.has(digest))
        #expect(try Data(contentsOf: paths.imagesFile) == broken)
    }

    @Test func missingCatalogIsValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore(paths: NoodlePaths.resolve(environment: ["NOODLE_HOME": root.path]))
        try await store.validateCatalog()
    }

    @Test func failedWritesLeavePublishedImagesAndBlobsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        let store = ImageStore(paths: paths)
        let layerDigest = try store.blobs.put(Data("original layer".utf8))
        let layer = LayerRef(digest: layerDigest, diffID: layerDigest, mediaType: MediaType.ociLayerTar, size: 14)
        var original = ImageConfig(); original.created = "2026-01-01T00:00:00Z"
        var other = ImageConfig(); other.created = "2026-02-01T00:00:00Z"
        let old = try await store.register(config: original, layers: [layer], tags: ["app:latest", "app:stable"])
        let second = try await store.register(config: other, layers: [], tags: ["other:latest"])
        let archive = root.appendingPathComponent("image.tar")
        try await store.save(["app:latest"], to: archive)
        let saved = try Data(contentsOf: paths.imagesFile)
        try FileManager.default.removeItem(at: paths.imagesFile)
        try FileManager.default.createDirectory(at: paths.imagesFile, withIntermediateDirectories: false)

        await #expect(throws: (any Error).self) { _ = try await store.tag("other", as: "app:latest") }
        await #expect(throws: (any Error).self) { _ = try await store.register(config: other, layers: [], tags: ["app:latest"]) }
        await #expect(throws: (any Error).self) { _ = try await store.load(from: archive, buildTags: ["leaked:latest"]) }
        await #expect(throws: (any Error).self) { _ = try await store.remove("app:stable") }
        await #expect(throws: (any Error).self) { _ = try await store.prune(danglingOnly: false, inUse: []) }
        await store.setUnpackedBytes(imageID: old.id, layerDigest: layerDigest, bytes: 99)
        #expect(try await store.resolve("app:latest").id == old.id)
        #expect(try await store.resolve("app:stable").id == old.id)
        #expect(try await store.resolve("other").id == second.id)
        await #expect(throws: (any Error).self) { _ = try await store.resolve("leaked:latest") }
        #expect(await store.get(id: old.id)?.layers.first?.unpackedBytes == nil)
        #expect(store.blobs.has(old.id) && store.blobs.has(layerDigest))
        _ = await store.collectBlobs()
        #expect(store.blobs.has(old.id) && store.blobs.has(layerDigest))

        try FileManager.default.removeItem(at: paths.imagesFile)
        try saved.write(to: paths.imagesFile)
        _ = try await store.tag("other", as: "recovered:latest")
        let reopened = ImageStore(paths: paths)
        #expect(try await reopened.resolve("app:latest").id == old.id)
        #expect(try await reopened.resolve("app:stable").id == old.id)
        #expect(try await reopened.resolve("recovered:latest").id == second.id)
    }

    @Test func partialLoadAndInvalidRegisterDoNotPublishTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore(paths: NoodlePaths(root: root))
        var original = ImageConfig(); original.created = "2026-01-01T00:00:00Z"
        var incoming = ImageConfig(); incoming.created = "2026-02-01T00:00:00Z"
        let old = try await store.register(config: original, layers: [], tags: ["app:latest"])
        await #expect(throws: (any Error).self) {
            _ = try await store.register(config: incoming, layers: [], tags: ["app:latest", "bad!:tag"])
        }
        #expect(try await store.resolve("app:latest").id == old.id)

        let archive = root.appendingPathComponent("partial.tar")
        let writer = try TarWriter(url: archive)
        try writer.addFile("first.json", data: JSONEncoder().encode(incoming))
        let manifest: [[String: Any]] = [
            ["Config": "first.json", "RepoTags": ["app:latest"], "Layers": [String]()],
            ["Config": "missing.json", "RepoTags": ["other:latest"], "Layers": [String]()]
        ]
        try writer.addFile("manifest.json", data: JSONSerialization.data(withJSONObject: manifest))
        try writer.finish()
        await #expect(throws: (any Error).self) { _ = try await store.load(from: archive) }
        #expect(try await store.resolve("app:latest").id == old.id)
        #expect(await store.all().count == 1)
        _ = try await store.tag("app:latest", as: "success:latest")
        let reopened = ImageStore(paths: NoodlePaths(root: root))
        #expect(try await reopened.resolve("app:latest").id == old.id)
        #expect(await reopened.all().count == 1)
    }

    @Test func durabilityFailurePreservesExistingCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        let store = ImageStore(paths: paths)
        var config = ImageConfig(); config.created = "2026-01-01T00:00:00Z"
        let image = try await store.register(config: config, layers: [], tags: ["keep:latest"])
        let before = try Data(contentsOf: paths.imagesFile)
        let blobDirectory = paths.blobsDir.appendingPathComponent("sha256")
        try FileManager.default.removeItem(at: blobDirectory)
        await #expect(throws: (any Error).self) { _ = try await store.tag("keep", as: "new:latest") }
        #expect(try Data(contentsOf: paths.imagesFile) == before)
        #expect(try await store.resolve("keep").id == image.id)
        await #expect(throws: (any Error).self) { _ = try await store.resolve("new:latest") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".images-") }.isEmpty)
    }

}

@Suite struct PinnedBlobTests {
    @Test func collectBlobsKeepsPinnedDigestsUntilUnpinned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths.resolve(environment: ["NOODLE_HOME": root.path])
        try paths.ensureDirectories()
        let store = ImageStore(paths: paths)
        let digest = try store.blobs.put(Data("in flight".utf8))
        await store.pin([digest]); await store.pin([digest])
        _ = await store.collectBlobs()
        #expect(store.blobs.has(digest))
        await store.unpin([digest])
        _ = await store.collectBlobs()
        #expect(store.blobs.has(digest), "one pin is still held")
        await store.unpin([digest])
        _ = await store.collectBlobs()
        #expect(!store.blobs.has(digest))
    }
}
