import Foundation
import NoodleCore

public actor ImageStore {
    public let paths: NoodlePaths
    public nonisolated let blobs: BlobStore
    public nonisolated let registry: RegistryClient
    var images: [String: LocalImage] = [:]
    var buildProvider: String?
    /// Digests an in-flight pull or commit has written but not yet registered; `collectBlobs` must keep them.
    var pinned: [String: Int] = [:]
    var catalogError: String?
    public var defaultPlatform: Platform = .arm64

    public func pin(_ digests: [String]) { for d in digests { pinned[d, default: 0] += 1 } }
    public func unpin(_ digests: [String]) {
        for d in digests { if let n = pinned[d], n > 1 { pinned[d] = n - 1 } else { pinned[d] = nil } }
    }

    public init(paths: NoodlePaths, registry: RegistryClient? = nil) {
        self.paths = paths
        self.blobs = BlobStore(paths: paths)
        self.registry = registry ?? RegistryClient(tempDirectory: paths.tmpDir)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: paths.imagesFile)
            images = try dec.decode([String: LocalImage].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new store has no catalog yet.
        } catch {
            catalogError = "cannot read image catalog: \(error)"
        }
    }

    public func validateCatalog() throws {
        if let catalogError { throw ImageError.io(catalogError) }
    }

    func persist(_ candidate: [String: LocalImage]) throws {
        try validateCatalog()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try ImageDurability.sync(paths.blobsDir.appendingPathComponent("sha256"))
        try ImageDurability.sync(paths.blobsDir)
        try ImageDurability.sync(paths.root)
        let temp = paths.root.appendingPathComponent(".images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try enc.encode(candidate).write(to: temp)
        try ImageDurability.sync(temp)
        try ImageDurability.rename(temp, to: paths.imagesFile)
        images = candidate
        do { try ImageDurability.sync(paths.root) }
        catch {
            catalogError = "image catalog durability is uncertain: \(error)"
            throw error
        }
    }

    public func search(term: String, limit: Int = 25, officialOnly: Bool = false) async throws -> [SearchResult] {
        try await registry.search(term: term, limit: limit, officialOnly: officialOnly)
    }
}
