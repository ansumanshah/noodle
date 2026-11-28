import Foundation
import NoodleCore
import NoodleImages

public struct BuildOptions: Sendable {
    public static let maximumContextBytes: Int64 = 1 << 30
    public static let contextLimitMessage = "build contexts are limited to 1 GiB, compressed and uncompressed"

    /// Base images the Mac resolves are sent to the classic builder uncompressed by Noodle, but as stored.
    public static let maximumBaseBytes: Int64 = 4 << 30
    public static let baseLimitMessage = "base images resolved on the Mac are limited to 4 GiB per build"

    let dockerfile: String
    let options: [String]
    let tags: [String]
    let args: [String: String]
    let pull: Bool

    public init(dockerfile: String = "Dockerfile", args: [String: String] = [:], labels: [String: String] = [:],
                tags: [String] = [], target: String? = nil, noCache: Bool = false, pull: Bool = false,
                network: String? = nil, platform: String? = nil) throws {
        let parts = dockerfile.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(""), !parts.contains(".."), !dockerfile.utf8.contains(0) else {
            throw EngineError.badRequest("Dockerfile must be a relative path inside the context")
        }
        guard [nil, "", "default", "bridge", "none"].contains(network) else {
            throw EngineError.badRequest("unsupported build network")
        }
        guard [nil, "", "linux/arm64", "linux/arm64/v8"].contains(platform) else {
            throw EngineError.badRequest("the local builder supports linux/arm64")
        }
        self.tags = try tags.map {
            guard !$0.contains(","), let ref = try? ImageReference.parse($0), ref.digest == nil else {
                throw EngineError.badRequest("invalid build tag: \($0)")
            }
            return ref.familiar
        }
        var opts: [String] = []
        for (prefix, values) in [("build-arg:", args), ("label:", labels)] {
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                guard !key.isEmpty, !key.contains("=") else { throw EngineError.badRequest("invalid build option key") }
                opts.append(prefix + key + "=" + value)
            }
        }
        if let target, !target.isEmpty { opts.append("target=" + target) }
        if noCache { opts.append("no-cache=") }
        if pull { opts.append("image-resolve-mode=pull") }
        if network == "none" { opts.append("force-network-mode=none") }
        guard opts.count <= 128, !opts.contains(where: { $0.utf8.contains(0) }) else {
            throw EngineError.badRequest("invalid or excessive build options")
        }
        self.dockerfile = dockerfile
        self.args = args
        self.pull = pull
        self.options = opts
    }
}

extension Engine {
    // Official moby/buildkit v0.35.0, linux/arm64. Only the pinned manifest can supply privileged tools.
    static let builderDigest = "sha256:7dc61a9fab7c7f5a50b1cdbbefa4180829e68c6c0172206eb54ad934de097ddf"

    public func buildImage(context: URL, options: BuildOptions,
                           progress: @escaping @Sendable (String) async throws -> Void) async throws -> String {
        try await withBuildHistory(context: context, options: options, progress: progress) { progress in
            try await withActivity {
                try await withLock("buildkit") {
                    try Task.checkCancellation()
                    let work = paths.tmpDir.appendingPathComponent("build-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: work) }
                    let (source, size) = try await Self.prepareBuildContext(context, in: work)
                    let ref = "moby/buildkit@" + Self.builderDigest
                    try await ensureGuest()
                    if (try? await imageStore.resolve(ref)) == nil {
                        try await progress("Downloading BuildKit v0.35.0…\n")
                        try await runPull(ref, platform: nil, credential: nil) { _ in }
                    }
                    let bases = try await prepareBuildBases(source: source, options: options, work: work)
                    return try await imageStore.withBuildProvider(ref) { builder in
                        try await self.runBuild(builder, source: source, size: size, work: work, options: options, bases: bases, progress: progress)
                    }
                }
            }
        }
    }

    @concurrent static func prepareBuildContext(_ context: URL, in work: URL) async throws -> (URL, Int64) {
        try Task.checkCancellation()
        var source = context
        var size = Int64(try context.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size <= BuildOptions.maximumContextBytes else { throw EngineError.badRequest(BuildOptions.contextLimitMessage) }
        if Gzip.isGzip(context) {
            source = work.appendingPathComponent("context.tar")
            do { size = try Gzip.decompress(context, to: source, maximumSize: BuildOptions.maximumContextBytes).size }
            catch Gzip.GzipError.tooLarge { throw EngineError.badRequest(BuildOptions.contextLimitMessage) }
        }
        guard size >= 512 else { throw EngineError.badRequest("empty or truncated build context") }
        return (source, size)
    }

    func verifyBuildProvider(_ builder: LocalImage) async throws {
        let manifest = try imageStore.blobs.read(Self.builderDigest)
        guard Digest.sha256(manifest) == Self.builderDigest,
              try JSONDecoder().decode(Manifest.self, from: manifest).layers?.map(\.digest) == builder.layers.map(\.digest) else {
            throw EngineError.internalError("builder layers do not match the pinned manifest")
        }
        try await ensureLayers(builder)
        // RUN uses the same resolver (including the Mac fallback) as default-bridge containers.
        // Builds can be the first guest workload, before a container creates that bridge.
        guard let network = networks.values.first(where: { $0.name == "bridge" && $0.builtin }) else {
            throw EngineError.internalError("default build network is missing")
        }
        try await ensureGuestNet(network)
    }

    private func runBuild(_ builder: LocalImage, source: URL, size: Int64, work: URL, options: BuildOptions,
                          bases: (options: [String], layout: URL?, size: Int64),
                          progress: @escaping @Sendable (String) async throws -> Void) async throws -> String {
        try await verifyBuildProvider(builder)
        let s = try await guest.openStream("build_image", [
            "layers": .strings(builder.layers.reversed().map(\.digest)), "size": .int(size),
            "dockerfile": .string(options.dockerfile), "options": .strings(bases.options), "base_size": .int(bases.size)
        ])
        defer { s.close() }
        return try await withTaskCancellationHandler {
            try await s.send(file: source)
            if let layout = bases.layout { try await s.send(file: layout) }
            let archive = work.appendingPathComponent("image.tar")
            guard FileManager.default.createFile(atPath: archive.path, contents: nil) else { throw POSIXError(.EIO) }
            let out = try FileHandle(forWritingTo: archive)
            defer { try? out.close() }
            var lastLog = ""
            while let frame = try await s.nextFrame() {
                switch frame.kind {
                case .stdout: try out.write(contentsOf: frame.payload)
                case .stderr:
                    let line = String(decoding: frame.payload, as: UTF8.self)
                    lastLog = String((lastLog + line).suffix(4096))
                    try await progress(line)
                case .exit:
                    guard frame.exitCode == 0 else { throw EngineError.badRequest("BuildKit failed\n" + lastLog) }
                    try out.close()
                    try Task.checkCancellation()
                    guard let image = try await imageStore.load(from: archive, buildTags: options.tags, maximumExpandedBytes: UploadLimits.maximumBytes).first else {
                        throw EngineError.internalError("build produced no image")
                    }
                    emit("image", "build", id: image.id, attributes: ["name": options.tags.first ?? image.id])
                    return image.id
                default: throw EngineError.internalError("unexpected builder response")
                }
            }
            throw EngineError.internalError("builder closed without reporting its exit status")
        } onCancel: { s.close() }
    }
}
