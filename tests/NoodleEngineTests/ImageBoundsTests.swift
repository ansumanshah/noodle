import Foundation
import Testing
import NoodleCore
@testable import NoodleImages

@Suite struct ImageBoundsTests {
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("noodle-bounds-\(UUID().uuidString.prefix(8))") }

    @Test func newRootIsPrivateAndOwnedLooseRootIsTightened() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        try paths.ensureDirectories()
        func mode() throws -> Int { (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try mode() == 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try paths.ensureDirectories()
        #expect(try mode() == 0o700)
    }

    @Test func metadataReadsRefuseOversizedFiles() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(paths: NoodlePaths(root: root))
        let digest = try store.put(Data("{}".utf8))
        #expect(try store.read(digest) == Data("{}".utf8))
        let big = root.appendingPathComponent("big.json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(BlobStore.metadataLimit) + 1)
        try h.close()
        #expect(throws: ImageError.self) { _ = try BlobStore.readMetadata(big) }
    }

    @Test func cachedBlobMustMatchDescriptorSize() throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BlobStore(paths: NoodlePaths(root: root))
        let digest = try store.put(Data("layer".utf8))
        try ImageStore.requireCachedSize(store, digest, 5)
        #expect(throws: ImageError.self) { try ImageStore.requireCachedSize(store, digest, Int64.max) }
    }

    @Test func imageSizeSaturatesInsteadOfTrapping() {
        let layer = LayerRef(digest: "sha256:" + String(repeating: "a", count: 64), diffID: "x", mediaType: "t", size: Int64.max)
        var img = LocalImage(id: "i", manifestDigest: nil, repoTags: [], repoDigests: [], config: ImageConfig(), layers: [layer, layer],
                             created: Date(), os: "linux", architecture: "arm64", variant: nil, parent: "", comment: "")
        #expect(img.size == Int64.max)
        img.layers = []
        #expect(img.size == 0)
    }
}
