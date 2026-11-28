import Foundation
import NoodleCore

extension ImageStore {
    // MARK: lookup

    public func all() -> [LocalImage] { Array(images.values) }

    public func get(id: String) -> LocalImage? { images[id] }

    /// Hold the worker's image and its lowerdirs until the transient build process exits.
    public func withBuildProvider<T: Sendable>(_ reference: String, _ body: @Sendable (LocalImage) async throws -> T) async throws -> T {
        guard buildProvider == nil else { throw ImageError.conflict("build worker is already in use") }
        let image = try resolve(reference)
        buildProvider = image.id
        defer { buildProvider = nil }
        return try await body(image)
    }

    /// Resolve a name (`ubuntu`, `ubuntu:22.04`, `repo@sha256:..`), full id, or unique id prefix.
    public func resolve(_ nameOrID: String) throws -> LocalImage {
        if let ref = try? ImageReference.parse(nameOrID) {
            let fam = ref.familiar
            if ref.tag != nil, let img = images.values.first(where: { $0.repoTags.contains(fam) }) { return img }
            if let d = ref.digest {
                if let img = images.values.first(where: { $0.repoDigests.contains(where: { $0.hasSuffix("@" + d) && Self.sameRepo($0, ref) }) }) { return img }
            }
        }
        let hex = nameOrID.hasPrefix("sha256:") ? String(nameOrID.dropFirst(7)) : nameOrID
        if !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            if let img = images["sha256:" + hex] { return img }
            let matches = images.values.filter { $0.id.dropFirst(7).hasPrefix(hex) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw ImageError.conflict("multiple IDs found with provided prefix: \(hex)") }
        }
        throw ImageError.notFound(nameOrID)
    }

    /// The local image a build base reference names: a digest pin needs that exact manifest, a tag needs the tag.
    public func buildBase(matching ref: ImageReference) -> LocalImage? {
        if let d = ref.digest {
            return images.values.first {
                $0.manifestDigest == d || $0.repoDigests.contains { $0.hasSuffix("@" + d) && Self.sameRepo($0, ref) }
            }
        }
        return images.values.first { $0.repoTags.contains(ref.familiar) }
    }

    /// True when this image was pulled from the reference's repository, so a registry holds a copy of it.
    public func cameFromRegistry(_ image: LocalImage, ref: ImageReference) -> Bool {
        image.repoDigests.contains { Self.sameRepo($0, ref) }
    }

    private static func sameRepo(_ repoDigest: String, _ ref: ImageReference) -> Bool {
        guard let at = repoDigest.firstIndex(of: "@") else { return false }
        guard let r = try? ImageReference.parse(String(repoDigest[..<at])) else { return false }
        return r.name == ref.name
    }

    public func list(all: Bool = false, filter: ImageListFilter = ImageListFilter()) -> [LocalImage] {
        var out = Array(images.values)
        if !all { out = out.filter { !$0.isDangling || self.hasChildren($0.id) == false } }
        if let d = filter.dangling { out = out.filter { $0.isDangling == d } }
        if !filter.references.isEmpty {
            out = out.filter { img in
                filter.references.contains { pat in
                    img.repoTags.contains { Self.glob(pat, $0) || Self.glob(pat, String($0.split(separator: ":").first ?? "")) }
                }
            }
        }
        for l in filter.labels {
            guard let f = LabelFilter(l) else { return [] }
            out = out.filter { f.matches($0.config.config?.labels ?? [:]) }
        }
        if let b = filter.before, let ref = try? resolve(b) { out = out.filter { $0.created < ref.created } }
        if let s = filter.since, let ref = try? resolve(s) { out = out.filter { $0.created > ref.created } }
        return out.sorted { $0.created > $1.created }
    }

    private func hasChildren(_ id: String) -> Bool { images.values.contains { $0.parent == id } }

    static func glob(_ pattern: String, _ s: String) -> Bool {
        fnmatch(pattern, s, 0) == 0
    }
    public func history(_ nameOrID: String) throws -> [ImageHistoryItem] {
        let img = try resolve(nameOrID)
        let entries = img.config.history ?? []
        var layerIndex = img.layers.count - 1
        var items: [ImageHistoryItem] = []
        for (i, e) in entries.enumerated().reversed() {
            let empty = e.emptyLayer ?? false
            var size: Int64 = 0
            if !empty, layerIndex >= 0 {
                size = img.layers[layerIndex].unpackedBytes ?? img.layers[layerIndex].size
                layerIndex -= 1
            }
            items.append(ImageHistoryItem(id: i == entries.count - 1 ? img.id : "<missing>",
                                          created: ISO8601.parse(e.created) ?? img.created,
                                          createdBy: e.createdBy ?? "", tags: i == entries.count - 1 ? img.repoTags : [],
                                          size: size, comment: e.comment ?? ""))
        }
        if items.isEmpty {
            items = [ImageHistoryItem(id: img.id, created: img.created, createdBy: "", tags: img.repoTags, size: img.size, comment: img.comment)]
        }
        return items
    }
}
