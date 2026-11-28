import Foundation
import NoodleCore

public struct LayerRef: Codable, Sendable, Equatable, Hashable {
    /// Digest of the blob as stored (compressed for registry layers, plain tar for committed layers).
    public var digest: String
    /// sha256 of the uncompressed tar.
    public var diffID: String
    public var mediaType: String
    public var size: Int64
    /// Uncompressed size reported by the guest after unpack.
    public var unpackedBytes: Int64?
    public init(digest: String, diffID: String, mediaType: String, size: Int64, unpackedBytes: Int64? = nil) {
        self.digest = digest; self.diffID = diffID; self.mediaType = mediaType; self.size = size; self.unpackedBytes = unpackedBytes
    }
    public var guestMedia: String { MediaType.guestMedia(forLayer: mediaType) }
}

public struct LocalImage: Codable, Sendable, Identifiable, Equatable {
    /// Config digest, `sha256:...` (Docker's image ID).
    public var id: String
    public var manifestDigest: String?
    public var repoTags: [String]       // familiar form: ubuntu:latest
    public var repoDigests: [String]    // ubuntu@sha256:...
    public var config: ImageConfig
    public var layers: [LayerRef]
    public var created: Date
    public var os: String
    public var architecture: String
    public var variant: String?
    public var parent: String
    public var comment: String

    public var shortID: String { Digest.short(id) }
    /// Docker's `Size`: unpacked bytes when known, else blob bytes.
    public var size: Int64 { layers.reduce(Int64(0)) {
        let (sum, overflow) = $0.addingReportingOverflow($1.unpackedBytes ?? $1.size)
        return overflow ? Int64.max : sum
    } }
    public var isDangling: Bool { repoTags.isEmpty && repoDigests.isEmpty }
}

public struct ImageHistoryItem: Sendable, Equatable {
    public var id: String        // image id for the top entry, "<missing>" otherwise
    public var created: Date
    public var createdBy: String
    public var tags: [String]
    public var size: Int64
    public var comment: String
}

public struct ImageRemoval: Sendable, Equatable {
    public enum Kind: Sendable { case untagged, deleted }
    public var kind: Kind
    public var value: String
}

public struct ImageListFilter: Sendable {
    public var references: [String] = []          // `reference=` patterns (glob)
    public var dangling: Bool?
    public var labels: [String] = []              // key or key=value
    public var before: String?
    public var since: String?
    public init() {}
}

public struct PruneImagesResult: Sendable {
    public var untagged: [String] = []
    public var deleted: [String] = []
    public var spaceReclaimed: Int64 = 0
}
