import Foundation
import NoodleCore
import NoodleImages

extension Engine {
    // MARK: tag / remove / prune / search

    static func imageTag(repo: String, tag: String?) throws -> String {
        do {
            var ref = try ImageReference.parse(repo)
            guard ref.digest == nil else { throw ImageError.invalid("tag cannot contain a digest") }
            if let tag, !tag.isEmpty { ref = ref.withTag(tag) }
            return try ImageReference.parse(ref.familiar).familiar
        } catch { throw EngineError.badRequest("invalid image reference: \(repo)") }
    }

    public func tagImage(_ name: String, repo: String, tag: String? = nil) async throws {
        let target = try Self.imageTag(repo: repo, tag: tag)
        do {
            let img = try await imageStore.tag(name, as: target)
            emit("image", "tag", id: img.id, attributes: ["name": target])
        } catch { throw mapImageError(error, name) }
    }

    public func removeImage(_ name: String, force: Bool = false) async throws -> [ImageDeleteItem] {
        imageRemovals += 1
        defer { imageRemovals -= 1 }
        let before = Set(await imageStore.all().flatMap { $0.layers.map(\.digest) })
        let used = Set(containers.values.map(\.imageID))   // after the last await before the store call
        let removals: [ImageRemoval]
        do { removals = try await imageStore.remove(name, force: force, inUse: { used.contains($0) }) }
        catch let e as ImageError {
            if case .conflict(let m) = e { throw EngineError.conflict(m) }
            throw mapImageError(e, name)
        }
        await dropOrphanLayers(before: before)
        for r in removals { emit("image", r.kind == .deleted ? "delete" : "untag", id: r.value, attributes: ["name": r.value]) }
        return removals.map { r in
            var d = ImageDeleteItem()
            if r.kind == .untagged { d.Untagged = r.value } else { d.Deleted = r.value }
            return d
        }
    }

    /// Layers no remaining image references go to the guest's removal list.
    func dropOrphanLayers(before: Set<String>) async {
        let after = Set(await imageStore.all().flatMap { $0.layers.map(\.digest) })
        let gone = Array(before.subtracting(after))
        guard !gone.isEmpty else { return }
        for rt in cleanupRuntimes() {
            rt.layers.subtract(gone)
            if await rt.vm.isRunning { _ = try? await rt.guest.call(GuestOp.layerRemove, ["digests": .strings(gone)], boot: false) }
            else { updatePending(rt) { $0.layers.append(contentsOf: gone) }; scheduleSave() }
        }
    }

    public func pruneImages(filters: Filters = Filters()) async throws -> ImagePruneResponse {
        imageRemovals += 1
        defer { imageRemovals -= 1 }
        let before = Set(await imageStore.all().flatMap { $0.layers.map(\.digest) })
        let used = Set(containers.values.map(\.imageID))   // after the last await before the store call
        let dangling = filters.bool("dangling") ?? true
        let r = try await imageStore.prune(danglingOnly: dangling, inUse: used)
        await dropOrphanLayers(before: before)
        var out = ImagePruneResponse()
        for u in r.untagged { var d = ImageDeleteItem(); d.Untagged = u; out.ImagesDeleted.append(d) }
        for x in r.deleted { var d = ImageDeleteItem(); d.Deleted = x; out.ImagesDeleted.append(d) }
        out.SpaceReclaimed = r.spaceReclaimed
        return out
    }

    public func searchImages(term: String, limit: Int = 25, filters: Filters = Filters()) async throws -> [ImageSearchItem] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { throw EngineError.badRequest("search term is required") }
        guard (1...100).contains(limit) else { throw EngineError.badRequest("limit \(limit) is outside the range of [1, 100]") }
        if let bad = filters.values.keys.sorted().first(where: { !["is-official", "is-automated", "stars"].contains($0) }) {
            throw EngineError.badRequest("invalid filter '\(bad)'")
        }
        func flag(_ key: String) throws -> Bool? {
            guard let v = filters[key].first else { return nil }
            guard ["true", "false", "1", "0"].contains(v) else { throw EngineError.badRequest("invalid filter '\(key)=\(v)'") }
            return v == "true" || v == "1"
        }
        let official = try flag("is-official"), automated = try flag("is-automated")
        var stars = 0
        if let v = filters["stars"].first {
            guard let n = Int(v), n >= 0 else { throw EngineError.badRequest("invalid filter 'stars=\(v)'") }
            stars = n
        }
        let filtered = official != nil || automated != nil || stars > 0
        let results: [SearchResult]
        do { results = try await imageStore.search(term: term, limit: filtered ? 100 : limit, officialOnly: official == true) }
        catch is CancellationError { throw CancellationError() }
        catch let e as ImageError { throw EngineError.internalError(e.description) }
        return results.filter { (official == nil || $0.isOfficial == official!) && (automated == nil || $0.isAutomated == automated!) && $0.starCount >= stars }
            .prefix(limit).map {
                ImageSearchItem(description: $0.description, is_official: $0.isOfficial, is_automated: $0.isAutomated, name: $0.name, star_count: $0.starCount)
            }
    }
}
