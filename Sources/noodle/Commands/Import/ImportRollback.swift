import Foundation
import NoodleCore

/// A failed load may have installed an image or moved tags. Undo only images supplied by this copy.
struct ImageImportRollback {
    let before: [ImageInfo]
    let incoming: Set<String>
    let tags: Set<String>

    init(names: [String], src: EngineEndpoint, dst: EngineEndpoint) throws {
        before = try dst.images(all: true)
        let details = try names.map { try src.inspect("images", $0) }
        incoming = Set(details.compactMap { $0["Id"] as? String })
        tags = Set(details.flatMap { $0["RepoTags"] as? [String] ?? [] })
    }

    func restore(_ dst: EngineEndpoint) throws {
        let current = try dst.images(all: true)
        let loaded = Set(current.map(\.id)).intersection(incoming)
        guard !loaded.isEmpty else { return }
        for image in before {
            for tag in image.tags where tags.contains(tag) {
                guard current.contains(where: { incoming.contains($0.id) && $0.tags.contains(tag) && $0.id != image.id }) else { continue }
                let repo: String, version: String
                if let split = tag.lastIndex(of: ":"), !tag[split...].contains("/") {
                    repo = String(tag[..<split]); version = String(tag[tag.index(after: split)...])
                } else { repo = tag; version = "latest" }
                try dst.call("POST", "/images/\(urlEscape(image.id))/tag?repo=\(urlEscape(repo))&tag=\(urlEscape(version))")
            }
        }
        // A load can add tags without adding an image ID. Delete only tags absent before this copy.
        let originalTags = Set(before.flatMap(\.tags))
        let existed = Set(before.map(\.id))
        for image in current where incoming.contains(image.id) && existed.contains(image.id) {
            for tag in image.tags where tags.contains(tag) && !originalTags.contains(tag) {
                try dst.call("DELETE", "/images/\(urlEscape(tag))", ok: [404])
            }
        }
        for id in loaded.subtracting(existed) { try dst.call("DELETE", "/images/\(urlEscape(id))?force=1", ok: [404]) }
    }
}
