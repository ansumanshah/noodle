import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    /// Raw tar of the merged rootfs.
    public func exportContainer(_ ref: String) async throws -> GuestStream {
        let id = try resolveContainerID(ref)
        try await ensureGuestContainer(id)
        return try await runtime(id).guest.openStream(StreamOp.export, ["container": .string(id)])
    }

    /// `GET /containers/{id}/archive`: raw tar of `path`. Parse the first header with `Engine.pathStat` for the stat header.
    public func archiveGet(_ ref: String, path: String) async throws -> GuestStream {
        let id = try resolveContainerID(ref)
        try await ensureGuestContainer(id)
        return try await runtime(id).guest.openStream(StreamOp.archiveGet, ["container": .string(id), "path": .string(path)])
    }

    /// `PUT /containers/{id}/archive`: write exactly `size` tar bytes, `finishWriting()`, then `readResult()`.
    public func archivePut(_ ref: String, path: String, size: Int64, copyUIDGID: Bool = false) async throws -> GuestStream {
        let id = try resolveContainerID(ref)
        if containers[id]?.hostConfig.ReadonlyRootfs == true { throw EngineError.conflict("container rootfs is marked read-only") }
        try await ensureGuestContainer(id)
        return try await runtime(id).guest.openStream(StreamOp.archivePut, ["container": .string(id), "path": .string(path), "size": .int(size), "copy_uid_gid": .bool(copyUIDGID)])
    }
}
