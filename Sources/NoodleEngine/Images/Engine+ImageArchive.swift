import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: save / load / import

    /// Write a `docker save` archive of `names` to `url`.
    public func saveImages(_ names: [String], to url: URL) async throws {
        do { try await imageStore.save(names, to: url) } catch { throw mapImageError(error, names.first ?? "") }
    }

    /// Load a (possibly gzip) `docker save` archive. Layers are unpacked lazily at first container start.
    public func loadImages(from url: URL) async throws -> [LocalImage] {
        do {
            let loaded = try await imageStore.load(from: url, maximumExpandedBytes: UploadLimits.maximumBytes)
            for i in loaded { emit("image", "load", id: i.id, attributes: ["name": i.repoTags.first ?? i.id]) }
            return loaded
        } catch Gzip.GzipError.tooLarge {
            throw EngineError.badRequest(UploadLimits.exceededMessage)
        } catch let e as ImageError { throw EngineError.badRequest(e.description) }
    }

    /// `docker import`: a rootfs tarball becomes a one-layer image.
    public func importImage(from tar: URL, repo: String? = nil, tag: String? = nil, message: String = "", changes: [String] = [], platform: String? = nil) async throws -> LocalImage {
        let tags = try repo.flatMap { $0.isEmpty ? nil : [try Self.imageTag(repo: $0, tag: tag)] } ?? []
        let blobs = imageStore.blobs
        let source = blobs.tempURL()
        defer { try? FileManager.default.removeItem(at: source) }
        let (digest, size) = try await Self.prepareImport(tar, to: source)
        // Pinned across install and registration so a concurrent collection cannot delete the layer in between.
        await imageStore.pin([digest])
        defer { Task { [imageStore] in await imageStore.unpin([digest]) } }
        try blobs.install(source, as: digest)
        let plat = platform.flatMap(Platform.parse) ?? .arm64
        var cfg = ImageConfig()
        cfg.architecture = plat.architecture; cfg.os = plat.os; cfg.variant = plat.variant
        cfg.created = ISO8601.string(Date())
        var rc = ImageConfig.RuntimeConfig()
        rc.env = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
        var ccfg = containerConfig(from: rc)
        Self.applyChanges(changes, to: &ccfg)
        cfg.config = Self.runtimeConfig(from: ccfg)
        cfg.history = [ImageConfig.HistoryEntry(created: cfg.created, createdBy: "", comment: message.isEmpty ? "Imported from -" : message)]
        let img = try await imageStore.register(config: cfg, layers: [LayerRef(digest: digest, diffID: digest, mediaType: MediaType.ociLayerTar, size: size)],
                                                tags: tags, comment: message)
        emit("image", "import", id: img.id, attributes: ["name": tags.first ?? img.id])
        return img
    }

    /// Gunzip or copy the upload and hash it off the actor: a 32 GiB import must not stall other engine calls.
    @concurrent static func prepareImport(_ tar: URL, to source: URL) async throws -> (digest: String, size: Int64) {
        if Gzip.isGzip(tar) {
            do { _ = try Gzip.decompress(tar, to: source, maximumSize: UploadLimits.maximumBytes) }
            catch Gzip.GzipError.tooLarge { throw EngineError.badRequest(UploadLimits.exceededMessage) }
        } else {
            try FileManager.default.copyItem(at: tar, to: source)
        }
        let digest = try Digest.sha256(file: source)
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (digest, size)
    }
}
