import Foundation
import NoodleCore

extension ImageStore {
    // MARK: save / load (docker archive)

    /// The tar is written off the actor; the images' blobs stay pinned so a concurrent prune cannot delete them mid-write.
    public func save(_ names: [String], to url: URL) async throws {
        let imgs = try names.map { try resolve($0) }
        let digests = imgs.flatMap { [$0.id] + $0.layers.map(\.digest) }
        pin(digests)
        defer { unpin(digests) }
        try await Self.writeArchive(imgs, to: url, blobs: blobs)
    }

    @concurrent static func writeArchive(_ imgs: [LocalImage], to url: URL, blobs: BlobStore) async throws {
        let w = try TarWriter(url: url)
        var written = Set<String>()
        var manifest: [[String: Any]] = []
        var repositories: [String: [String: String]] = [:]
        for img in imgs {
            let cfgName = img.id.dropFirst(7) + ".json"
            if written.insert(String(cfgName)).inserted { try w.addFile(String(cfgName), data: blobs.read(img.id)) }
            var layerPaths: [String] = []
            for l in img.layers {
                let dir = String(l.digest.dropFirst(7))
                let path = dir + "/layer.tar"
                layerPaths.append(path)
                if written.insert(path).inserted {
                    try w.addDirectory(dir)
                    try w.addFile(path, from: blobs.url(l.digest))
                }
            }
            manifest.append(["Config": String(cfgName), "RepoTags": img.repoTags, "Layers": layerPaths])
            for t in img.repoTags {
                let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { repositories[parts[0], default: [:]][parts[1]] = String(img.id.dropFirst(7)) }
            }
        }
        try w.addFile("manifest.json", data: JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]))
        try w.addFile("repositories", data: JSONSerialization.data(withJSONObject: repositories, options: [.sortedKeys]))
        try w.finish()
    }

    /// Load a `docker save` archive (plain or gzip). Returns the loaded images.
    public func load(from url: URL, buildTags: [String]? = nil, expectedBuildConfig: String? = nil, maximumExpandedBytes: Int64 = .max, progress: @escaping ProgressHandler = { _ in }) async throws -> [LocalImage] {
        try validateCatalog()
        if let expectedBuildConfig {
            guard expectedBuildConfig.hasPrefix("sha256:"), Digest.isValid(expectedBuildConfig), buildTags != nil else {
                throw ImageError.invalid("invalid builder config digest or tags")
            }
            guard !Gzip.isGzip(url) else { throw ImageError.invalid("builder archive must be uncompressed") }
        }
        // Gunzip, extraction, hashing and blob installs run off the actor; only the catalog change below runs on it.
        let items = try await readArchive(url, single: buildTags != nil, expectedBuildConfig: expectedBuildConfig,
                                          maximumExpandedBytes: maximumExpandedBytes, progress: progress)
        let digests = items.flatMap { $0.layers.map(\.digest) }
        defer { unpin(digests) }
        var images = images
        var loaded: [LocalImage] = []
        for item in items {
            let cfg = item.config
            let id = try blobs.put(item.configData)
            var img = images[id] ?? LocalImage(
                id: id, manifestDigest: nil, repoTags: [], repoDigests: [], config: cfg, layers: item.layers,
                created: ISO8601.parse(cfg.created) ?? Date(), os: cfg.os ?? "linux", architecture: cfg.architecture ?? "arm64",
                variant: cfg.variant, parent: "", comment: "")
            for t in buildTags ?? item.repoTags {
                do { Self.setTag(&images, familiar: try ImageReference.parse(t).familiar, on: &img) }
                catch { throw ImageError.invalid("invalid RepoTag \(t)") }
            }
            images[id] = img
            loaded.append(img)
        }
        try persist(images)
        return loaded
    }

    struct ArchiveImage: Sendable {
        let configData: Data
        let config: ImageConfig
        let layers: [LayerRef]
        let repoTags: [String]
    }

    /// Extracts and installs the archive's layers. Each layer is pinned before install; the caller unpins on success.
    @concurrent nonisolated func readArchive(_ url: URL, single: Bool, expectedBuildConfig: String?, maximumExpandedBytes: Int64,
                                             progress: @escaping ProgressHandler) async throws -> [ArchiveImage] {
        var pinned: [String] = []
        do { return try await readArchive(url, single: single, expectedBuildConfig: expectedBuildConfig,
                                          maximumExpandedBytes: maximumExpandedBytes, progress: progress, pinned: &pinned) }
        catch { await unpin(pinned); throw error }
    }

    @concurrent nonisolated private func readArchive(_ url: URL, single: Bool, expectedBuildConfig: String?, maximumExpandedBytes: Int64,
                                                     progress: @escaping ProgressHandler, pinned: inout [String]) async throws -> [ArchiveImage] {
        var source = url
        var cleanup: [URL] = []
        defer { for c in cleanup { try? FileManager.default.removeItem(at: c) } }
        if Gzip.isGzip(url) {
            let plain = blobs.tempURL()
            cleanup.append(plain)
            _ = try Gzip.decompress(url, to: plain, maximumSize: maximumExpandedBytes)
            source = plain
        }
        let reader = try TarReader(url: source)
        let workDir = paths.tmpDir.appendingPathComponent("load-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        cleanup.append(workDir)

        var files: [String: URL] = [:]
        var links: [String: String] = [:]
        var n = 0
        while let e = try reader.next() {
            let name = e.name.hasPrefix("./") ? String(e.name.dropFirst(2)) : e.name
            if e.isFile {
                n += 1
                let dest = workDir.appendingPathComponent("f\(n)")
                try reader.copy(e, to: dest)
                files[name] = dest
            } else if e.type == UInt8(ascii: "2") || e.type == UInt8(ascii: "1") {
                links[name] = e.linkName.hasPrefix("./") ? String(e.linkName.dropFirst(2)) : e.linkName
            }
        }
        func file(_ name: String) -> URL? {
            if let f = files[name] { return f }
            if var l = links[name] {
                if !l.contains("/") || files[l] == nil, let dir = name.split(separator: "/").dropLast().first, files[l] == nil {
                    l = String(dir).isEmpty ? l : (String(dir) + "/" + l)
                    if let f = files[l] { return f }
                }
                return files[l]
            }
            return nil
        }
        guard let mf = file("manifest.json"),
              let items = try JSONSerialization.jsonObject(with: BlobStore.readMetadata(mf)) as? [[String: Any]] else {
            throw ImageError.invalid("archive has no manifest.json (only docker save format is supported)")
        }
        if single, items.count != 1 { throw ImageError.invalid("builder must produce exactly one image") }
        var out: [ArchiveImage] = []
        for item in items {
            guard let cfgName = item["Config"] as? String, let cfgFile = file(cfgName),
                  let layerNames = item["Layers"] as? [String] else { throw ImageError.invalid("bad manifest.json entry") }
            let cfgData = try BlobStore.readMetadata(cfgFile)
            if let expectedBuildConfig {
                let actual = Digest.sha256(cfgData)
                guard actual == expectedBuildConfig else { throw ImageError.digestMismatch(expected: expectedBuildConfig, actual: actual) }
            }
            let cfg = try JSONDecoder().decode(ImageConfig.self, from: cfgData)
            let diffIDs = cfg.rootfs?.diffIDs ?? []
            guard diffIDs.count == layerNames.count else { throw ImageError.invalid("layer count does not match config") }
            guard diffIDs.allSatisfy(Digest.isValid) else { throw ImageError.invalid("bad diff id in image config") }
            var refs: [LayerRef] = []
            for (i, ln) in layerNames.enumerated() {
                guard let lf = file(ln) else { throw ImageError.invalid("missing layer \(ln)") }
                let gz = Gzip.isGzip(lf)
                let digest = try Digest.sha256(file: lf)
                let size = (try FileManager.default.attributesOfItem(atPath: lf.path)[.size] as? NSNumber)?.int64Value ?? 0
                await pin([digest]); pinned.append(digest)
                if !blobs.has(digest) {
                    let keep = blobs.tempURL()
                    try FileManager.default.copyItem(at: lf, to: keep)
                    try blobs.install(keep, as: digest)
                }
                refs.append(LayerRef(digest: digest, diffID: diffIDs[i], mediaType: gz ? MediaType.dockerLayerGzip : MediaType.ociLayerTar, size: size))
                progress(ProgressEvent(id: Digest.short(digest), status: "Loading layer"))
            }
            out.append(ArchiveImage(configData: cfgData, config: cfg, layers: refs, repoTags: (item["RepoTags"] as? [String]) ?? []))
        }
        return out
    }
}
