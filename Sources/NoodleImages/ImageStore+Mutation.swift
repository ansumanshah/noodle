import Foundation
import NoodleCore

extension ImageStore {
    // MARK: register / tag / remove

    /// Add an image built locally (commit, import, load). Writes the config blob; layers must already be in the blob store.
    @discardableResult
    public func register(config: ImageConfig, layers: [LayerRef], tags: [String] = [], parent: String = "", comment: String = "") throws -> LocalImage {
        try validateCatalog()
        var cfg = config
        cfg.rootfs = ImageConfig.RootFS(diffIDs: layers.map(\.diffID))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(cfg)
        let id = try blobs.put(data)
        var images = images
        var img = images[id] ?? LocalImage(
            id: id, manifestDigest: nil, repoTags: [], repoDigests: [], config: cfg, layers: layers,
            created: ISO8601.parse(cfg.created) ?? Date(), os: cfg.os ?? "linux", architecture: cfg.architecture ?? "arm64",
            variant: cfg.variant, parent: parent, comment: comment)
        for t in tags { Self.setTag(&images, familiar: (try ImageReference.parse(t)).familiar, on: &img) }
        images[id] = img
        try persist(images)
        return img
    }

    public func setUnpackedBytes(imageID: String, layerDigest: String, bytes: Int64) {
        guard var img = images[imageID], let i = img.layers.firstIndex(where: { $0.digest == layerDigest }) else { return }
        var images = images
        img.layers[i].unpackedBytes = bytes
        images[imageID] = img
        try? persist(images)
    }

    public func tag(_ source: String, as target: String) throws -> LocalImage {
        var img = try resolve(source)
        let ref = try ImageReference.parse(target)
        guard ref.digest == nil else { throw ImageError.invalid("invalid reference format: tag cannot contain a digest") }
        var images = images
        Self.setTag(&images, familiar: ref.familiar, on: &img)
        images[img.id] = img
        try persist(images)
        return img
    }

    /// Remove by name or id. `inUse` returns true when a container (running or not) uses the image id.
    /// Mirrors `docker rmi`: a tag with siblings is only untagged; the last reference deletes the image.
    public func remove(_ nameOrID: String, force: Bool = false,
                       inUse: @Sendable (String) -> Bool = { _ in false }) throws -> [ImageRemoval] {
        var img = try resolve(nameOrID)
        var images = images
        var out: [ImageRemoval] = []
        if img.id == buildProvider { throw ImageError.conflict("image is being used by the build worker") }
        let used = inUse(img.id)
        var taggedName: String?
        if let ref = try? ImageReference.parse(nameOrID), ref.tag != nil, img.repoTags.contains(ref.familiar) { taggedName = ref.familiar }

        if let t = taggedName {
            if img.repoTags.count > 1 || (used && force) {
                img.repoTags.removeAll { $0 == t }
                images[img.id] = img
                try persist(images)
                return [ImageRemoval(kind: .untagged, value: t)]
            }
            if used { throw ImageError.conflict("conflict: unable to remove repository reference \"\(t)\" (must force) - container is using its referenced image \(img.shortID)") }
        } else {
            if img.repoTags.count > 1 && !force {
                throw ImageError.conflict("conflict: unable to delete \(img.shortID) (must be forced) - image is referenced in multiple repositories")
            }
            if used {
                guard force else { throw ImageError.conflict("conflict: unable to delete \(img.shortID) (cannot be forced) - image is being used by a container") }
                for t in img.repoTags { out.append(ImageRemoval(kind: .untagged, value: t)) }
                img.repoTags = []
                images[img.id] = img
                try persist(images)
                return out
            }
        }
        for t in img.repoTags { out.append(ImageRemoval(kind: .untagged, value: t)) }
        for d in img.repoDigests { out.append(ImageRemoval(kind: .untagged, value: d)) }
        images[img.id] = nil
        out.append(ImageRemoval(kind: .deleted, value: img.id))
        try persist(images)
        collectBlobs()
        return out
    }
}
