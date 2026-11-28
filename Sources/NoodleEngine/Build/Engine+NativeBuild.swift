import Foundation
import NoodleCore

extension Engine {
    /// Disk verification and subprocess downloads run on a utility queue, away from NIO.
    public func prepareNativeBuildAdapter(using adapter: BuildKitAdapter? = nil) async throws -> URL {
        try await BuildKitAdapterDownloads.shared.install(adapter ?? BuildKitAdapter(paths: paths))
    }

    private func launchNativeBuilder(_ generation: UUID) async throws -> NativeBuilder {
        let binary = try await prepareNativeBuildAdapter()
        let (ready, report) = AsyncThrowingStream<NativeBuilder, Error>.makeStream()
        let owner = Task {
            do {
                try await withLock("buildkit") {
                    let ref = "moby/buildkit@" + Self.builderDigest
                    try await ensureGuest()
                    if (try? await imageStore.resolve(ref)) == nil {
                        try await runPull(ref, platform: nil, credential: nil) { _ in }
                    }
                    try Task.checkCancellation()
                    try await imageStore.withBuildProvider(ref) { image in
                        try await self.verifyBuildProvider(image)
                        let stream = try await self.guest.openStream("buildkit_native", ["layers": .strings(image.layers.reversed().map(\.digest))])
                        defer { stream.close() }
                        let builder = try await self.startAdapter(stream, binary: binary, generation: generation)
                        report.yield(builder)
                        report.finish()
                        // Retain the verified lowerdirs and cache lease throughout every solve.
                        for await _ in builder.exit.stream {}
                        await self.retire(builder)
                    }
                }
            } catch { report.finish(throwing: error) }
        }
        return try await withTaskCancellationHandler {
            var next = ready.makeAsyncIterator()
            guard let builder = try await next.next() else { throw CancellationError() }
            return builder
        } onCancel: { owner.cancel() }
    }

    private func retire(_ builder: NativeBuilder) async {
        await finishAbandonedNativeBuilds(builder)
        if nativeImportOwner === builder { nativeImportOwner = nil; nativeBaseBlobs = [] }
        if nativeGeneration == builder.generation { nativeBuilder = nil }
        builder.stop()
    }

    /// Only the transient adapter can name one of its own completed archives for import.
    public func importNativeImage(token: String, file: String, digest: String, tags: [String]) async throws -> String {
        guard let owner = nativeImportOwner, token == owner.token else { throw EngineError.badRequest("invalid build capability") }
        guard Digest.isValid(digest), file.hasPrefix("image-"), file.hasSuffix(".tar"), (11...40).contains(file.count),
              file.dropFirst(6).dropLast(4).utf8.allSatisfy({ (48...57).contains($0) }),
              tags.count <= 128 else { throw EngineError.badRequest("invalid worker output") }
        let options = try BuildOptions(tags: tags)
        let archive = owner.directory.appendingPathComponent(file)
        try Task.checkCancellation()
        guard let image = try await imageStore.load(from: archive, buildTags: options.tags, expectedBuildConfig: digest).first else {
            throw EngineError.internalError("builder produced no image")
        }
        emit("image", "build", id: image.id, attributes: ["name": options.tags.first ?? image.id])
        return image.id
    }

    private func startAdapter(_ stream: GuestStream, binary: URL, generation: UUID) async throws -> NativeBuilder {
        // Short private directory avoids Darwin's 104-byte sockaddr_un limit.
        var template = Array("/tmp/noodle-bk.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
        let dir = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        let sock = dir.appendingPathComponent("adapter.sock").path
        let p = Process()
        let builder = NativeBuilder(process: p, stream: stream, directory: dir, socketPath: sock, generation: generation)
        do {
            guard FileManager.default.createFile(atPath: dir.appendingPathComponent("import-token").path,
                                                  contents: Data(builder.token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw POSIXError(.EIO)
            }
            let input = try stream.channel.handoffReadDescriptor()
            defer { try? input.close() }
            try await stream.write(Data([1]))
            p.executableURL = binary; p.arguments = [sock, dir.path, paths.socket.path, String(getpid())]; p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.environment = [:]
            try p.run()
            for _ in 0..<500 {
                try Task.checkCancellation()
                guard p.isRunning else { throw EngineError.internalError("BuildKit stopped") }
                if FileManager.default.fileExists(atPath: sock) { nativeImportOwner = builder; return builder }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw EngineError.internalError("BuildKit did not start")
        } catch { builder.stop(); throw error }
    }

    public func withNativeBuildConnection(_ body: @Sendable (GuestStream) async throws -> Void) async throws {
        releaseNativeBuilder?.cancel()
        let client = UUID()
        nativeConnections.insert(client)
        defer { releaseNativeClient(client) }
        try await withTaskCancellationHandler {
            let stream = try await openNativeConnection()
            defer { stream.close() }
            try await body(stream)
        } onCancel: { Task { await self.releaseNativeClient(client) } }
    }

    private func releaseNativeClient(_ client: UUID) {
        guard nativeConnections.remove(client) != nil, nativeConnections.isEmpty else { return }
        releaseNativeBuilder = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            // A cancelled gRPC connection can close before its Solve defer writes
            // history. Give only these active builds a bounded chance to finish.
            if let owner = nativeImportOwner {
                for _ in 0..<70 {
                    if owner.buildHistoryRecords.isEmpty { break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            if nativeConnections.isEmpty { await stopNativeBuilder() }
        }
    }

    private func openNativeConnection() async throws -> GuestStream {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let starting: Task<NativeBuilder, Error>
            if let shared = nativeBuilder { starting = shared }
            else {
                let generation = UUID()
                nativeGeneration = generation
                starting = Task { try await launchNativeBuilder(generation) }
                nativeBuilder = starting
            }
            let builder: NativeBuilder
            do { builder = try await starting.value }
            catch {
                if nativeBuilder == starting { nativeBuilder = nil }
                throw error
            }
            try Task.checkCancellation()
            do { return try await builder.connect() }
            catch {
                await retire(builder)
                if attempt == 1 { throw error }
            }
        }
        throw EngineError.internalError("native builder unavailable")
    }

    func stopNativeBuilder() async {
        if let owner = nativeImportOwner { await finishAbandonedNativeBuilds(owner) }
        let old = nativeBuilder
        nativeBuilder = nil
        nativeGeneration = nil
        nativeImportOwner = nil
        nativeBaseBlobs = []
        old?.cancel()
        if let builder = try? await old?.value { builder.stop() }
    }
}
