import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: guest layer cache

    /// Populate missing guest layers, consulting boot-local digest knowledge when trustCache permits it.
    /// True means no guest presence query was needed; false means layer_has was called.
    @discardableResult
    func ensureLayers(_ image: LocalImage, trustCache: Bool = true, in rt: GuestRuntime? = nil) async throws -> Bool {
        let rt = rt ?? main
        if trustCache, image.layers.allSatisfy({ rt.layers.contains($0.digest) }) { return true }
        let r = try await rt.guest.call(GuestOp.layerHas, ["digests": .strings(image.layers.map(\.digest)), "diff_ids": .strings(image.layers.map(\.diffID))])
        let present = Set(r["present"]?.array?.compactMap(\.string) ?? [])
        for layer in image.layers where !present.contains(layer.digest) {
            try await unpackLayerOnce(layer, imageID: image.id, in: rt)
        }
        rt.layers.formUnion(image.layers.map(\.digest))
        return false
    }

    /// Guest `create` is the authority on layer presence. When it fails after we trusted the cache,
    /// forget the cache, check for real and retry once.
    ///
    /// With `thenStart` the guest creates and starts in one round trip and the start result comes back.
    /// Nil means the container still has to be started: nothing needed creating, or the agent predates the flag.
    /// A failure of the start part is thrown as it is, with the container recorded as created, which is where
    /// two calls would leave it. A lost reply is thrown too: the container may be running, so nothing is repeated.
    @discardableResult
    func createInGuest(_ image: LocalImage, usedCache: Bool, _ op: String, _ args: [String: JSONValue], thenStart: Bool = false,
                       in rt: GuestRuntime? = nil) async throws -> [String: JSONValue]? {
        let rt = rt ?? main
        let args = withLogLimits(op, args)
        // `docker run` creates at attach and again at start. The second is a no-op when the spec did not change.
        let id = args["container"]?.string ?? ""
        if rt.containers.contains(id), rt.createdSpecs[id] == args.hashValue { return nil }
        if thenStart {
            var combined = args
            combined["start"] = .bool(true)
            do {
                let r = try await rt.guest.call(op, combined)
                rt.createdSpecs[id] = args.hashValue
                return r["pid"] == nil ? nil : r
            } catch let e as GuestError where e.stage == "start" {
                rt.createdSpecs[id] = args.hashValue
                rt.containers.insert(id)
                throw e
            } catch let e as GuestError where e.reported && usedCache {
                _ = e // the create part failed after the layer cache was trusted: check for real below
            } catch let e as GuestError where !e.reported && !rt.containers.contains(id) {
                // The reply was lost, so the guest may have created and started the container. Stop it and drop it
                // before failing, or the host would keep a "created" record for a container that is running.
                _ = try? await rt.guest.call(GuestOp.kill, ["container": .string(id), "signal": .int(9)], boot: false)
                _ = try? await rt.guest.call(GuestOp.remove, ["container": .string(id)], boot: false)
                throw e
            }
        }
        do { _ = try await rt.guest.call(op, args) } catch {
            guard usedCache else { throw error }
            rt.layers.subtract(image.layers.map(\.digest))
            try await ensureLayers(image, trustCache: false, in: rt)
            _ = try await rt.guest.call(op, args)
        }
        rt.createdSpecs[id] = args.hashValue
        return nil
    }

    /// One layer of a pull: skip the unpack (and the blob transfer to the guest) when the guest already has it verified.
    func ensureLayer(_ layer: LayerRef, in rt: GuestRuntime? = nil) async throws {
        let rt = rt ?? main
        if rt.layers.contains(layer.digest) { return }
        let r = try await rt.guest.call(GuestOp.layerHas, ["digests": .strings([layer.digest]), "diff_ids": .strings([layer.diffID])])
        if r["present"]?.array?.compactMap(\.string).contains(layer.digest) != true {
            try await unpackLayerOnce(layer, imageID: nil, in: rt)
        }
        rt.layers.insert(layer.digest)
    }

    func unpackLayerOnce(_ layer: LayerRef, imageID: String?, in rt: GuestRuntime? = nil) async throws {
        let rt = rt ?? main
        let key = layer.digest + "|" + layer.diffID
        if let t = rt.unpacking[key] { try await t.value; return }
        let blobs = imageStore.blobs
        let t = Task { [guest = rt.guest, imageStore] in
            let stream = try await guest.openStream(StreamOp.unpackLayer, [
                "digest": .string(layer.digest), "diff_id": .string(layer.diffID), "media": .string(layer.guestMedia), "size": .int(layer.size)])
            defer { stream.close() }
            try await stream.send(file: blobs.url(layer.digest))
            stream.finishWriting()
            let r = try await stream.readResult()
            guard r["diff_id"]?.string == layer.diffID else {
                throw EngineError.internalError("layer \(layer.digest) did not verify as \(layer.diffID)")
            }
            if let id = imageID, let bytes = r["bytes"]?.int { await imageStore.setUnpackedBytes(imageID: id, layerDigest: layer.digest, bytes: bytes) }
        }
        rt.unpacking[key] = t
        defer { rt.unpacking[key] = nil }
        try await t.value
    }

    /// Register a container with the guest if it forgot it (after a VM sleep). Idempotent.
    func ensureGuestContainer(_ id: String) async throws {
        try await withLock(id) { try await ensureGuestContainerLocked(id) }
    }

    private func ensureGuestContainerLocked(_ id: String) async throws {
        guard let c = containers[id] else { throw EngineError.notFound("No such container: \(id)") }
        let rt = runtime(for: c)
        try await ensureGuest(rt)
        guard !rt.containers.contains(id) else { return }
        guard let image = await imageStore.get(id: c.imageID) else { throw EngineError.notFound("No such image: \(c.image)") }
        let usedCache = try await ensureLayers(image, in: rt)
        // docker cp reaches a volume of a container that has not started, so the volume must exist in the guest already.
        for m in c.guestMounts where m.kind == "volume" { try await ensureGuestVolume(m.source, in: rt) }
        var spec = try buildSpec(c, primary: c.endpoints[c.primaryNetwork], net: networks.values.first { $0.name == c.primaryNetwork })
        for i in spec.mounts.indices where spec.mounts[i].kind == "bind" {
            let source = spec.mounts[i].source
            let type = (try? FileManager.default.attributesOfItem(atPath: source)[.type]) as? FileAttributeType
            spec.mounts[i].source = HostShareKey.guestSource(hostPath: source, isDirectory: type != .typeRegular, readOnly: spec.mounts[i].readOnly)
        }
        spec.layers = image.layers.reversed().map(\.digest)
        let (op, args) = try GuestRequests.create(container: id, spec: spec)
        try await createInGuest(image, usedCache: usedCache, op, args, in: rt)
        rt.containers.insert(id)
    }
}
