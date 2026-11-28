import Foundation

struct FinderFailure: Error, Sendable {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

struct FinderNode: Sendable {
    var name: String
    var kind: String
    var size: Int64 = 0
    var mtime: Int64 = 0
    var isDirectory: Bool { kind == "directory" }
}

/// One request owns this reader. Neither file bodies nor directory entries are accumulated.
final class FinderGuestReader: @unchecked Sendable {
    let stream: GuestStream
    private var carry = Data()
    init(_ stream: GuestStream) { self.stream = stream }
    func record() async throws -> [String: JSONValue] {
        let head = try await exact(4)
        let length = head.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 4096 else { throw FinderFailure(502, "invalid guest metadata") }
        let data = try await exact(length)
        guard let object = try JSONDecoder().decode(JSONValue.self, from: data).object else {
            throw FinderFailure(502, "invalid guest metadata")
        }
        if let error = object["error"]?.string {
            throw GuestError(error, errno: Int32(clamping: object["errno"]?.int ?? 0))
        }
        return object
    }
    private func exact(_ count: Int) async throws -> Data {
        while carry.count < count {
            guard let chunk = try await stream.readChunk() else { throw FinderFailure(502, "guest stream ended early") }
            carry.append(chunk)
        }
        let result = Data(carry.prefix(count))
        carry = Data(carry.dropFirst(count))
        return result
    }
    func select(_ action: String, offset: Int64 = 0, count: Int64 = 0) async throws {
        let body: JSONValue = ["action": .string(action), "offset": .int(offset), "count": .int(count)]
        try await stream.write(LengthPrefixed.encode(JSONEncoder().encode(body)))
    }
    func bytes() async throws -> Data? {
        if !carry.isEmpty { let result = carry; carry = Data(); return result }
        return try await stream.readChunk()
    }
    func close() { stream.close() }
}

struct FinderResource: Sendable {
    var node: FinderNode
    var children: [FinderNode] = []
    var guest: FinderGuestReader?
}

extension Engine {
    /// Synthetic namespace reads use host state only. Guest access is explicit and never starts a container.
    func finderResource(_ parts: [String]) async throws -> FinderResource {
        try Task.checkCancellation()
        if parts.isEmpty {
            return FinderResource(node: FinderNode(name: "Noodle", kind: "directory"), children: [
                FinderNode(name: "containers", kind: "directory"), FinderNode(name: "volumes", kind: "directory")])
        }
        guard parts[0] == "containers" || parts[0] == "volumes" else { throw FinderFailure(404, "resource not found") }
        if parts.count == 1 {
            // The engine already holds this namespace; bound the extra per-request snapshot as well.
            let count = parts[0] == "containers" ? containers.count : volumes.count
            guard count <= 4096 else { throw FinderFailure(507, "namespace exceeds 4096 entries") }
            let names = parts[0] == "containers" ? containers.values.map(\.name) : Array(volumes.keys)
            return FinderResource(node: FinderNode(name: parts[0], kind: "directory"),
                                  children: names.sorted().map { FinderNode(name: $0, kind: "directory") })
        }
        let name = parts[1], path = parts.dropFirst(2).joined(separator: "/")
        if parts[0] == "containers" {
            guard let c = containers.values.first(where: { $0.name == name }) else { throw FinderFailure(404, "container not found") }
            try await ensureGuestContainer(c.id)
            try Task.checkCancellation()
            guard containers[c.id]?.name == name else { throw FinderFailure(404, "container removed or renamed") }
            return try await Self.finderOpen(runtime(for: c), args: ["container": .string(c.id), "path": .string(path)], name: parts.last ?? name)
        }
        guard volumes[name] != nil, !deletingVolumes.contains(name) else { throw FinderFailure(404, "volume not found") }
        // VolumeRecord has no persistent VM placement. Probe roots, never create an empty
        // volume on the wrong disk. Only an explicit volume request can wake these VMs.
        var selected: GuestRuntime?
        for rt in cleanupRuntimes() {
            try await ensureGuest(rt)
            try Task.checkCancellation()
            if pendingLists(rt).volumes.contains(name) { continue }
            do {
                let root = try await Self.finderOpen(rt, args: ["volume": .string(name), "path": .string("")], name: name)
                root.guest?.close()
                if selected != nil { throw FinderFailure(409, "volume exists in both VMs") }
                selected = rt
            } catch let error as GuestError where error.errno == ENOENT {
                continue
            }
        }
        guard volumes[name] != nil, !deletingVolumes.contains(name) else { throw FinderFailure(404, "volume removed") }
        if let selected {
            return try await Self.finderOpen(selected, args: ["volume": .string(name), "path": .string(path)], name: parts.last ?? name)
        }
        // A host-created volume has no on-disk directory until first use.
        if path.isEmpty { return FinderResource(node: FinderNode(name: name, kind: "directory")) }
        throw FinderFailure(404, "file not found")
    }

    private static func finderOpen(_ rt: GuestRuntime, args: [String: JSONValue], name: String) async throws -> FinderResource {
        let stream = try await rt.guest.openStream("finder_read", args)
        let reader = FinderGuestReader(stream)
        do {
            return try await withTaskCancellationHandler {
                let metadata = try await reader.record()
                try Task.checkCancellation()
                guard let kind = metadata["kind"]?.string, kind == "file" || kind == "directory",
                      let size = metadata["size"]?.int, size >= 0, let mtime = metadata["mtime"]?.int else {
                    throw FinderFailure(502, "invalid guest metadata")
                }
                return FinderResource(node: FinderNode(name: name, kind: kind, size: size, mtime: mtime), guest: reader)
            } onCancel: { reader.close() }
        } catch { reader.close(); throw error }
    }
}
