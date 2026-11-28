import Foundation
import NoodleCore
import NoodleImages

/// An image the Mac resolved for a build. The builder reads it as an OCI content store, so registry
/// credentials and the Mac-only local store never reach the guest.
struct BuildBase: Sendable {
    /// Digest of the manifest (or index) the Dockerfile reference resolves to.
    let digest: String
    /// Every blob a reader needs, manifest included.
    let blobs: [String]
}

extension Engine {
    /// Resolves a `FROM` reference on the Mac. Nil means the builder can pull it itself, anonymously, as before.
    ///
    /// A local tag wins over a registry of the same name, as it does for Docker. An image the Mac pulled from a public
    /// registry is left to the builder, which caches it. Loopback registries and registries the Mac holds credentials
    /// for are pulled here, because the guest can reach neither and must not receive the credentials.
    func resolveBuildBase(_ reference: String, pull: Bool) async throws -> BuildBase? {
        guard let ref = try? ImageReference.parse(reference) else { return nil }
        let hostOnly = await imageStore.registry.isHostOnly(ref)
        var local = await imageStore.buildBase(matching: ref)
        if let image = local {
            if pull {
                guard hostOnly else { return nil }
                local = nil
            } else if !hostOnly, await imageStore.cameFromRegistry(image, ref: ref) {
                return nil
            }
        }
        if local == nil {
            guard hostOnly else { return nil }
            do { try await runPull(ref.description, platform: nil, credential: nil) { _ in } }
            catch {
                throw EngineError.badRequest("cannot pull base image \(reference) on the Mac: \(error). If the registry needs credentials, run docker login for it first")
            }
            local = await imageStore.buildBase(matching: ref)
        }
        guard let image = local else { throw EngineError.notFound("base image \(reference)") }
        return try baseDescriptor(for: image, pinned: ref.digest)
    }

    private func baseDescriptor(for image: LocalImage, pinned: String?) throws -> BuildBase {
        let blobs = imageStore.blobs
        var digests: [String] = []
        let top: String
        if let pinned {
            guard blobs.has(pinned) else { throw EngineError.notFound("manifest \(pinned)") }
            top = pinned
            digests.append(pinned)
            if let manifest = image.manifestDigest, manifest != pinned {
                guard blobs.has(manifest) else { throw EngineError.notFound("manifest \(manifest)") }
                digests.append(manifest)
            }
        } else {
            func descriptor(_ type: String, _ digest: String, _ size: Int64) -> [String: Any] {
                ["mediaType": type, "digest": digest, "size": size]
            }
            let manifest: [String: Any] = [
                "schemaVersion": 2, "mediaType": MediaType.ociManifest,
                "config": descriptor("application/vnd.oci.image.config.v1+json", image.id, blobs.size(image.id) ?? 0),
                "layers": image.layers.map { descriptor(Self.ociLayerType($0.mediaType), $0.digest, $0.size) },
            ]
            top = try blobs.put(try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]))
            digests.append(top)
        }
        digests.append(image.id)
        digests.append(contentsOf: image.layers.map(\.digest))
        for digest in digests where !blobs.has(digest) { throw EngineError.notFound("blob \(digest)") }
        return BuildBase(digest: top, blobs: Array(NSOrderedSet(array: digests)) as? [String] ?? digests)
    }

    static func ociLayerType(_ mediaType: String) -> String {
        if mediaType.hasSuffix("zstd") { return MediaType.ociLayerZstd }
        if mediaType.hasSuffix("gzip") { return "application/vnd.oci.image.layer.v1.tar+gzip" }
        return MediaType.ociLayerTar
    }

    /// Lets the native builder's helper read a resolved base back, only while it holds the build capability.
    public func nativeBaseDigest(token: String, reference: String, pull: Bool) async throws -> String? {
        guard let owner = nativeImportOwner, token == owner.token else { throw EngineError.badRequest("invalid build capability") }
        return try await withActivity {
            guard let base = try await resolveBuildBase(reference, pull: pull) else { return nil }
            nativeBaseBlobs.formUnion(base.blobs)
            return base.digest
        }
    }

    public func nativeBaseBlob(token: String, digest: String) throws -> (URL, Int64) {
        guard let owner = nativeImportOwner, token == owner.token, nativeBaseBlobs.contains(digest),
              let size = imageStore.blobs.size(digest) else { throw EngineError.notFound("blob \(digest)") }
        return (imageStore.blobs.url(digest), size)
    }

    /// A tar of an OCI layout holding every resolved base, for the classic builder's `--oci-layout`.
    static func writeBaseLayout(_ bases: [BuildBase], store: BlobStore, to url: URL) throws -> Int64 {
        let tar = try TarWriter(url: url)
        try tar.addFile("oci-layout", data: Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8))
        try tar.addFile("index.json", data: Data("{\"schemaVersion\":2,\"manifests\":[]}".utf8))
        try tar.addDirectory("blobs")
        try tar.addDirectory("blobs/sha256")
        var written = Set<String>()
        for digest in bases.flatMap(\.blobs) where written.insert(digest).inserted {
            try tar.addFile("blobs/sha256/" + digest.dropFirst(7), from: store.url(digest))
        }
        try tar.finish()
        return tar.bytesWritten
    }

    /// Resolves what the Dockerfile in the build context names. Returns the builder options and the layout tar, if any.
    func prepareBuildBases(source: URL, options: BuildOptions, work: URL) async throws -> (options: [String], layout: URL?, size: Int64) {
        guard let text = try await Self.readDockerfile(in: source, path: options.dockerfile) else { return (options.options, nil, 0) }
        var bases: [(String, BuildBase)] = []
        for ref in DockerfileRefs.externalImages(in: text, args: options.args) {
            try Task.checkCancellation()
            if let base = try await resolveBuildBase(ref, pull: options.pull) { bases.append((Self.contextKey(ref), base)) }
        }
        guard !bases.isEmpty else { return (options.options, nil, 0) }
        let layout = work.appendingPathComponent("bases.tar")
        let size = try Self.writeBaseLayout(bases.map(\.1), store: imageStore.blobs, to: layout)
        guard size <= BuildOptions.maximumBaseBytes else { throw EngineError.badRequest(BuildOptions.baseLimitMessage) }
        return (options.options + bases.map { "context:\($0.0)=oci-layout:noodle@\($0.1.digest)" }, layout, size)
    }

    /// The name BuildKit's Dockerfile frontend looks a `context:` entry up by: the familiar form without `:latest`.
    static func contextKey(_ reference: String) -> String {
        guard let ref = try? ImageReference.parse(reference) else { return reference }
        let familiar = ref.familiar
        return familiar.hasSuffix(":latest") ? String(familiar.dropLast(7)) : familiar
    }

    @concurrent static func readDockerfile(in context: URL, path: String) async throws -> String? {
        let reader = try TarReader(url: context)
        while let entry = try reader.next() {
            let name = entry.name.hasPrefix("./") ? String(entry.name.dropFirst(2)) : entry.name
            if name == path, entry.isFile { return String(decoding: try reader.readData(entry, limit: 4 << 20), as: UTF8.self) }
        }
        return nil
    }
}
