import Foundation
import NoodleCore

extension ImageStore {
    /// Delete blobs no image references.
    @discardableResult
    public func collectBlobs() -> Int64 {
        guard catalogError == nil else { return 0 }
        var live = Set(pinned.keys)
        for img in images.values {
            live.insert(img.id)
            if let m = img.manifestDigest { live.insert(m) }
            for l in img.layers { live.insert(l.digest) }
            for d in img.repoDigests { if let at = d.lastIndex(of: "@") { live.insert(String(d[d.index(after: at)...])) } }
        }
        var freed: Int64 = 0
        for (digest, size) in blobs.all() where !live.contains(digest) {
            blobs.remove(digest); freed += size
        }
        return freed
    }

    public func prune(danglingOnly: Bool, inUse: Set<String>) throws -> PruneImagesResult {
        try validateCatalog()
        var images = images
        var result = PruneImagesResult()
        for img in images.values where img.id != buildProvider && !inUse.contains(img.id) {
            let candidate = danglingOnly ? img.isDangling : true
            if candidate && (img.isDangling || !danglingOnly) {
                if !danglingOnly { result.untagged += img.repoTags }
                result.deleted.append(img.id)
                result.spaceReclaimed += img.size
                images[img.id] = nil
            }
        }
        try persist(images)
        _ = collectBlobs()
        result.spaceReclaimed += blobs.sweepPartials()     // half-downloaded blobs nobody is filling
        return result
    }
}
