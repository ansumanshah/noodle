import Foundation
import NoodleCore

extension ImageStore {
    // MARK: pull

    public struct PullResult: Sendable {
        public var image: LocalImage
        public var updated: Bool
        public var digest: String
    }

    /// Pull `reference`. `onLayer` runs once per layer, after its blob is present (use it to unpack into the guest).
    public func pull(_ reference: String, platform: Platform? = nil, credential: RegistryCredential? = nil,
                     progress: @escaping ProgressHandler,
                     onLayer: (@Sendable (LayerRef) async throws -> Void)? = nil) async throws -> PullResult {
        let ref = try ImageReference.parse(reference)
        let platform = platform ?? defaultPlatform
        try validateCatalog()
        progress(ProgressEvent(id: ref.tag ?? ref.digest, status: "Pulling from \(ref.familiarName)"))

        if ref.digest == nil, let result = try await pullIfCurrent(ref, platform: platform, credential: credential, progress: progress, onLayer: onLayer) {
            return result
        }

        let (top, resolved) = try await registry.resolve(ref, platform: platform, credential: credential)
        let manifest = try JSONDecoder().decode(Manifest.self, from: resolved.data)
        guard let cfgDesc = manifest.config, let layerDescs = manifest.layers else {
            throw ImageError.invalid("unsupported manifest for \(ref.familiar)")
        }
        for d in [cfgDesc.digest, resolved.digest, top.digest] + layerDescs.map(\.digest) where !Digest.isValid(d) {
            throw ImageError.invalid("bad digest \(d) in manifest for \(ref.familiar)")
        }
        let held = [cfgDesc.digest, resolved.digest, top.digest] + layerDescs.map(\.digest)
        pin(held)
        defer { unpin(held) }
        guard cfgDesc.size >= 0, cfgDesc.size <= BlobStore.metadataLimit else { throw ImageError.invalid("image config is too large for \(ref.familiar)") }
        guard layerDescs.allSatisfy({ $0.size >= 0 }) else { throw ImageError.invalid("negative layer size in manifest for \(ref.familiar)") }
        if blobs.has(cfgDesc.digest) { try Self.requireCachedSize(blobs, cfgDesc.digest, cfgDesc.size) }
        else { try await registry.fetchBlob(ref, digest: cfgDesc.digest, expectedSize: cfgDesc.size, into: blobs, credential: credential) }
        let cfgData = try blobs.read(cfgDesc.digest)
        let cfg = try JSONDecoder().decode(ImageConfig.self, from: cfgData)
        let diffIDs = cfg.rootfs?.diffIDs ?? []
        guard diffIDs.count == layerDescs.count else { throw ImageError.invalid("layer count does not match config") }

        let layers: [LayerRef] = zip(layerDescs, diffIDs).map {
            LayerRef(digest: $0.digest, diffID: $1, mediaType: $0.mediaType, size: $0.size)
        }

        // Download with bounded parallelism, unpack hook per layer as each finishes.
        let known = Set(images.values.flatMap { $0.layers.map(\.digest) })
        let registry = self.registry, blobs = self.blobs
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = layers.makeIterator()
            var running = 0
            func addNext(_ g: inout ThrowingTaskGroup<Void, Error>) -> Bool {
                guard let layer = iterator.next() else { return false }
                let short = Digest.short(layer.digest)
                g.addTask {
                    if blobs.has(layer.digest) {
                        try Self.requireCachedSize(blobs, layer.digest, layer.size)
                        progress(ProgressEvent(id: short, status: known.contains(layer.digest) ? "Already exists" : "Already downloaded"))
                    } else {
                        progress(ProgressEvent(id: short, status: "Pulling fs layer"))
                        let throttle = Throttle()
                        try await registry.fetchBlob(ref, digest: layer.digest, expectedSize: layer.size, into: blobs, credential: credential) { done, total in
                            if throttle.allow() { progress(ProgressEvent(id: short, status: "Downloading", current: done, total: total > 0 ? total : layer.size)) }
                        }
                        progress(ProgressEvent(id: short, status: "Download complete"))
                    }
                    if let onLayer {
                        try await onLayer(layer)
                        progress(ProgressEvent(id: short, status: "Pull complete"))
                    }
                }
                return true
            }
            while running < 3, addNext(&group) { running += 1 }
            while try await group.next() != nil {
                running -= 1
                if addNext(&group) { running += 1 }
            }
        }

        _ = try blobs.put(resolved.data)
        if top.digest != resolved.digest { _ = try blobs.put(top.data) }

        var images = images
        let id = cfgDesc.digest
        let existed = images[id] != nil
        var img = images[id] ?? LocalImage(
            id: id, manifestDigest: resolved.digest, repoTags: [], repoDigests: [], config: cfg, layers: layers,
            created: ISO8601.parse(cfg.created) ?? Date(timeIntervalSince1970: 0),
            os: cfg.os ?? "linux", architecture: cfg.architecture ?? platform.architecture, variant: cfg.variant,
            parent: "", comment: "")
        img.manifestDigest = resolved.digest
        if let tag = ref.tag { Self.setTag(&images, familiar: ref.withTag(tag).familiar, on: &img) }
        let repoDigest = ref.familiarName + "@" + top.digest
        if !img.repoDigests.contains(repoDigest) { img.repoDigests.append(repoDigest) }
        images[id] = img
        try persist(images)

        progress(ProgressEvent(status: "Digest: \(top.digest)"))
        progress(ProgressEvent(status: existed ? "Status: Image is up to date for \(ref.familiar)" : "Status: Downloaded newer image for \(ref.familiar)"))
        return PullResult(image: img, updated: !existed, digest: top.digest)
    }

    /// A cached blob must be as long as its descriptor says, or the descriptor size would poison the catalogue.
    static func requireCachedSize(_ blobs: BlobStore, _ digest: String, _ expected: Int64) throws {
        guard blobs.size(digest) == expected else { throw ImageError.invalid("cached blob \(digest) does not match its descriptor size") }
    }

    /// Fast path for a tag that is already present: one HEAD, and when the registry still serves the digest
    /// this platform's image was pulled from (and every blob is intact), skip the manifest and token round trips.
    private func pullIfCurrent(_ ref: ImageReference, platform: Platform, credential: RegistryCredential?, progress: ProgressHandler,
                               onLayer: (@Sendable (LayerRef) async throws -> Void)?) async throws -> PullResult? {
        guard let tag = ref.tag, let top = await registry.manifestDigest(ref, credential: credential) else { return nil }
        let repoDigest = ref.familiarName + "@" + top
        guard var img = images.values.first(where: {
            $0.repoDigests.contains(repoDigest) && platform.matches(os: $0.os, architecture: $0.architecture, variant: $0.variant)
        }), blobs.has(img.id), img.layers.allSatisfy({ blobs.has($0.digest) }) else { return nil }
        // The callback awaits VM work; keep the blobs from collection meanwhile, and fall back to a full pull if the image was removed.
        let held = [img.id] + img.layers.map(\.digest) + [img.manifestDigest].compactMap { $0 }
        pin(held)
        defer { unpin(held) }
        if let onLayer {
            for layer in img.layers { try await onLayer(layer) }
            // Another pull may have tagged the image meanwhile; tag the current record, not the snapshot.
            guard let current = images[img.id] else { return nil }
            img = current
        }
        let familiar = ref.withTag(tag).familiar
        if !img.repoTags.contains(familiar) {
            var images = images
            Self.setTag(&images, familiar: familiar, on: &img)
            images[img.id] = img
            try persist(images)
        }
        progress(ProgressEvent(status: "Digest: \(top)"))
        progress(ProgressEvent(status: "Status: Image is up to date for \(ref.familiar)"))
        return PullResult(image: img, updated: false, digest: top)
    }

    /// Move `familiar` to `img`, removing it from any other image.
    static func setTag(_ images: inout [String: LocalImage], familiar: String, on img: inout LocalImage) {
        for (k, var other) in images where other.id != img.id && other.repoTags.contains(familiar) {
            other.repoTags.removeAll { $0 == familiar }
            images[k] = other
        }
        if !img.repoTags.contains(familiar) { img.repoTags.append(familiar) }
    }
}

/// Lets a progress callback fire at most ~8 times per second.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    var last = DispatchTime(uptimeNanoseconds: 0)
    func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now()
        if now.uptimeNanoseconds &- last.uptimeNanoseconds > 120_000_000 { last = now; return true }
        return false
    }
}
