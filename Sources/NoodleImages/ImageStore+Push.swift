import Foundation
import NoodleCore

extension ImageStore {
    // MARK: push

    public func push(_ reference: String, credential: RegistryCredential? = nil, progress: @escaping ProgressHandler) async throws -> String {
        let ref = try ImageReference.parse(reference)
        guard let tag = ref.tag ?? Optional(ref.digest) ?? nil else { throw ImageError.invalid("no tag") }
        let img = try resolve(ref.tag != nil ? ref.familiar : reference)
        try validateCatalog()
        progress(ProgressEvent(status: "The push refers to repository [\(ref.name)]"))

        // Layers: gzip anything stored as plain tar.
        var descriptors: [Descriptor] = []
        for layer in img.layers {
            let short = Digest.short(layer.digest)
            var digest = layer.digest, size = layer.size, media = layer.mediaType
            var uploadFile = blobs.url(layer.digest)
            var tmp: URL?
            if layer.guestMedia == "tar" {
                let gz = blobs.tempURL()
                let r = try Gzip.compress(uploadFile, to: gz)
                digest = r.outputDigest; size = r.outputSize; media = MediaType.dockerLayerGzip
                uploadFile = gz; tmp = gz
            } else if media == MediaType.ociLayerZstd {
                media = MediaType.ociLayerZstd
            }
            defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
            if try await registry.blobExists(ref, digest: digest, credential: credential) {
                progress(ProgressEvent(id: short, status: "Layer already exists"))
            } else {
                progress(ProgressEvent(id: short, status: "Preparing"))
                let throttle = Throttle()
                try await registry.pushBlob(ref, digest: digest, file: uploadFile, credential: credential) { done, total in
                    if throttle.allow() { progress(ProgressEvent(id: short, status: "Pushing", current: done, total: total)) }
                }
                progress(ProgressEvent(id: short, status: "Pushed"))
            }
            descriptors.append(Descriptor(mediaType: media == MediaType.ociLayerTar ? MediaType.dockerLayerGzip : media, digest: digest, size: size))
        }
        // Config + manifest
        let cfgData = try blobs.read(img.id)
        if try await !registry.blobExists(ref, digest: img.id, credential: credential) {
            let tmp = blobs.tempURL()
            try cfgData.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await registry.pushBlob(ref, digest: img.id, file: tmp, credential: credential)
        }
        struct Out: Encodable {
            var schemaVersion = 2
            var mediaType = MediaType.dockerManifest
            var config: Descriptor
            var layers: [Descriptor]
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try enc.encode(Out(config: Descriptor(mediaType: MediaType.dockerConfig, digest: img.id, size: Int64(cfgData.count)), layers: descriptors))
        let digest = try await registry.pushManifest(ref, reference: tag, data: manifestData, mediaType: MediaType.dockerManifest, credential: credential)
        progress(ProgressEvent(status: "\(tag): digest: \(digest) size: \(manifestData.count)"))
        var images = images
        var updated = img
        let rd = ref.familiarName + "@" + digest
        if !updated.repoDigests.contains(rd) { updated.repoDigests.append(rd) }
        images[img.id] = updated
        try persist(images)
        return digest
    }
}
