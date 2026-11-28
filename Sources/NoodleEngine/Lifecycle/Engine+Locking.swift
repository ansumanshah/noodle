import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

extension Engine {
    // MARK: helpers shared by the extensions

    func emit(_ type: String, _ action: String, id: String, attributes: [String: String] = [:]) {
        revokePublicLinks(type: type, action: action, id: id, attributes: attributes)
        let now = Date().timeIntervalSince1970
        let ev = EventMessage(Type: type, Action: action, Actor: EventActor(ID: id, Attributes: attributes),
                              time: Int64(now), timeNano: Int64(now * 1_000_000_000),
                              status: type == "container" || type == "image" ? action : nil,
                              id: id, from: attributes["image"])
        hub.publish(ev)
    }

    func containerAttributes(_ c: ContainerRecord, extra: [String: String] = [:]) -> [String: String] {
        var a = c.config.Labels ?? [:]
        a["image"] = c.image
        a["name"] = c.name
        for (k, v) in extra { a[k] = v }
        return a
    }

    func resolveContainerID(_ ref: String) throws -> String {
        let r = ref.hasPrefix("/") ? String(ref.dropFirst()) : ref
        if containers[r] != nil { return r }
        if let c = containers.values.first(where: { $0.name == r }) { return c.id }
        if !r.isEmpty {
            let m = containers.values.filter { $0.id.hasPrefix(r) }
            if m.count == 1 { return m[0].id }
            if m.count > 1 { throw EngineError.conflict("Multiple IDs found with provided prefix: \(r)") }
        }
        throw EngineError.notFound("No such container: \(ref)")
    }

    func lock(_ key: String) async {
        if !held.contains(key) { held.insert(key); return }
        await withCheckedContinuation { locks[key, default: []].append($0) }
    }

    func unlock(_ key: String) {
        if var q = locks[key], !q.isEmpty {
            let next = q.removeFirst()
            locks[key] = q.isEmpty ? nil : q
            next.resume()
        } else {
            held.remove(key)
        }
    }

    func withLock<T: Sendable>(_ key: String, _ body: () async throws -> T) async throws -> T {
        await lock(key)
        defer { unlock(key) }
        return try await body()
    }

    func refreshBusy() {
        let inWorkload = containers.values.filter(\.isRunningLike).map(Self.usesWorkload)
        let mainBusy = inWorkload.contains(false) || main.streamCount > 0 || activeOps > 0
        let workloadBusy = inWorkload.contains(true) || workload.streamCount > 0
        let (mainVM, workloadVM) = (main.vm, workload.vm)
        Task { await mainVM.setBusy(mainBusy) }
        Task { await workloadVM.setBusy(workloadBusy) }
    }

    func streamCountChanged(_ rt: GuestRuntime, _ n: Int) { rt.streamCount = n; refreshBusy() }

    func withActivity<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        activeOps += 1; refreshBusy()
        defer { activeOps -= 1; refreshBusy() }
        return try await body()
    }
}
