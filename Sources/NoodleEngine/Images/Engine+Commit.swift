import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// `docker commit`. Returns the new image id.
    public func commitContainer(_ ref: String, repo: String? = nil, tag: String? = nil, comment: String = "", author: String = "",
                                changes: [String] = [], config override: ContainerConfig? = nil, pause: Bool = true) async throws -> String {
        let tags = try repo.flatMap { $0.isEmpty ? nil : [try Self.imageTag(repo: $0, tag: tag)] } ?? []
        let id = try resolveContainerID(ref)
        guard let c = containers[id] else { throw EngineError.notFound("No such container: \(ref)") }
        guard let base = await imageStore.get(id: c.imageID) else { throw EngineError.notFound("No such image: \(c.image)") }
        try await ensureGuestContainer(id)

        let blobs = imageStore.blobs
        let (tmp, digest, size) = try await withLock(id) { try await collectCommitTar(id, c, pause: pause) }
        var layers = base.layers
        var history = base.config.history ?? []
        let now = ISO8601.string(Date())
        let empty = size <= 1024
        await imageStore.pin([digest])
        defer { Task { [imageStore] in await imageStore.unpin([digest]) } }
        if empty {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try blobs.install(tmp, as: digest)
            layers.append(LayerRef(digest: digest, diffID: digest, mediaType: MediaType.ociLayerTar, size: size))
        }
        history.append(ImageConfig.HistoryEntry(created: now, createdBy: commandString(c), author: author.isEmpty ? nil : author,
                                                comment: comment.isEmpty ? nil : comment, emptyLayer: empty ? true : nil))
        var cfg = base.config
        cfg.created = now; cfg.history = history
        if !author.isEmpty { cfg.author = author }
        var cc = override ?? c.config
        Self.applyChanges(changes, to: &cc)
        cfg.config = Self.runtimeConfig(from: cc)
        let img = try await imageStore.register(config: cfg, layers: layers, tags: tags, parent: base.id, comment: comment)
        emit("container", "commit", id: id, attributes: containerAttributes(c))
        return img.id
    }
}

extension Engine {
    /// Marks a complete archive from the guest; EOF without it means the worker failed part way.
    static let tarDoneTrailer = Data("NOODLE-TAR-DONE\n".utf8)

    /// Writes the container's changes to a temp blob. Freezes the cgroup while collecting when `pause` is set and the
    /// container is running, and always thaws it again if this call froze it. Caller holds the container lock.
    private func collectCommitTar(_ id: String, _ c: ContainerRecord, pause: Bool) async throws -> (URL, String, Int64) {
        let tmp = imageStore.blobs.tempURL()
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw POSIXError(.EIO) }
        let out = try FileHandle(forWritingTo: tmp)
        var hasher = Digest.Hasher()
        var size: Int64 = 0
        let allowance = UploadLimits.commitAllowance(in: tmp.deletingLastPathComponent())
        let guest = runtime(id).guest
        let froze = pause && containers[id]?.status == .running
        do {
            if froze { _ = try await guest.call(GuestOp.pause, ["container": .string(id)]) }
            let stream = try await guest.openStream(StreamOp.commit, ["container": .string(id)])
            defer { stream.close() }
            var tail = Data()
            let n = Self.tarDoneTrailer.count
            while let chunk = try await stream.readChunk() {
                tail.append(chunk)
                guard tail.count > n else { continue }
                let body = tail.prefix(tail.count - n)
                tail = Data(tail.suffix(n))
                size += Int64(body.count)
                guard size <= allowance else {
                    throw EngineError.badRequest("the changes in container \(c.name) are larger than the commit limit of \(allowance) bytes. Move the data to a volume or raise NOODLE_MAX_COMMIT_BYTES")
                }
                try out.write(contentsOf: body); hasher.update(body)
            }
            guard tail == Self.tarDoneTrailer else { throw EngineError.internalError("the guest stopped before finishing the commit archive of container \(c.name)") }
            try out.close()
            if froze { _ = try await guest.call(GuestOp.unpause, ["container": .string(id)]) }
        } catch {
            try? out.close(); try? FileManager.default.removeItem(at: tmp)
            if froze { _ = try? await guest.call(GuestOp.unpause, ["container": .string(id)]) }
            throw error
        }
        return (tmp, hasher.finalize(), size)
    }
}
