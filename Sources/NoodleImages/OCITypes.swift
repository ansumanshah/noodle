import Foundation

public enum MediaType {
    public static let dockerManifest = "application/vnd.docker.distribution.manifest.v2+json"
    public static let dockerManifestList = "application/vnd.docker.distribution.manifest.list.v2+json"
    public static let dockerConfig = "application/vnd.docker.container.image.v1+json"
    public static let dockerLayerGzip = "application/vnd.docker.image.rootfs.diff.tar.gzip"
    public static let ociManifest = "application/vnd.oci.image.manifest.v1+json"
    public static let ociIndex = "application/vnd.oci.image.index.v1+json"
    public static let ociLayerZstd = "application/vnd.oci.image.layer.v1.tar+zstd"
    public static let ociLayerTar = "application/vnd.oci.image.layer.v1.tar"
    public static let acceptManifests = [ociIndex, dockerManifestList, ociManifest, dockerManifest].joined(separator: ", ")

    public static func isIndex(_ t: String) -> Bool { t == ociIndex || t == dockerManifestList }

    /// Guest unpack media keyword for a layer media type.
    public static func guestMedia(forLayer t: String) -> String {
        if t.hasSuffix("zstd") { return "zstd" }
        if t.hasSuffix("gzip") { return "gzip" }
        if t.hasSuffix(".tar") { return "tar" }
        return "gzip"
    }
}

public struct Descriptor: Codable, Sendable, Hashable {
    public var mediaType: String
    public var digest: String
    public var size: Int64
    public var platform: PlatformSpec?
    public var annotations: [String: String]?

    public init(mediaType: String, digest: String, size: Int64, platform: PlatformSpec? = nil, annotations: [String: String]? = nil) {
        self.mediaType = mediaType; self.digest = digest; self.size = size; self.platform = platform; self.annotations = annotations
    }
}

public struct PlatformSpec: Codable, Sendable, Hashable {
    public var architecture: String
    public var os: String
    public var variant: String?
}

public struct Manifest: Codable, Sendable {
    public var schemaVersion: Int
    public var mediaType: String?
    public var config: Descriptor?
    public var layers: [Descriptor]?
    public var manifests: [Descriptor]?   // index / manifest list
    public var annotations: [String: String]?
}

/// Docker/OCI image configuration blob. Unknown fields are preserved by `raw` when re-serialising is needed.
public struct ImageConfig: Codable, Sendable, Equatable {
    public var architecture: String?
    public var os: String?
    public var variant: String?
    public var created: String?
    public var author: String?
    public var config: RuntimeConfig?
    public var rootfs: RootFS?
    public var history: [HistoryEntry]?

    public struct RuntimeConfig: Codable, Sendable, Equatable {
        public var user: String?
        public var env: [String]?
        public var entrypoint: [String]?
        public var cmd: [String]?
        public var workingDir: String?
        public var labels: [String: String]?
        public var exposedPorts: [String: EmptyObject]?
        public var volumes: [String: EmptyObject]?
        public var stopSignal: String?
        public var healthcheck: Health?
        public var shell: [String]?
        public var onBuild: [String]?
        public init() {}

        enum CodingKeys: String, CodingKey {
            case user = "User", env = "Env", entrypoint = "Entrypoint", cmd = "Cmd", workingDir = "WorkingDir"
            case labels = "Labels", exposedPorts = "ExposedPorts", volumes = "Volumes", stopSignal = "StopSignal"
            case healthcheck = "Healthcheck", shell = "Shell", onBuild = "OnBuild"
        }
    }
    public struct Health: Codable, Sendable, Equatable {
        public var test: [String]?
        public var interval: Int64?
        public var timeout: Int64?
        public var startPeriod: Int64?
        public var startInterval: Int64?
        public var retries: Int?
        public init() {}
        enum CodingKeys: String, CodingKey {
            case test = "Test", interval = "Interval", timeout = "Timeout", startPeriod = "StartPeriod", startInterval = "StartInterval", retries = "Retries"
        }
    }
    public struct EmptyObject: Codable, Sendable, Equatable { public init() {} }
    public struct RootFS: Codable, Sendable, Equatable {
        public var type: String
        public var diffIDs: [String]
        enum CodingKeys: String, CodingKey { case type, diffIDs = "diff_ids" }
        public init(type: String = "layers", diffIDs: [String]) { self.type = type; self.diffIDs = diffIDs }
    }
    public struct HistoryEntry: Codable, Sendable, Equatable {
        public var created: String?
        public var createdBy: String?
        public var author: String?
        public var comment: String?
        public var emptyLayer: Bool?
        enum CodingKeys: String, CodingKey {
            case created, createdBy = "created_by", author, comment, emptyLayer = "empty_layer"
        }
        public init(created: String?, createdBy: String?, author: String? = nil, comment: String? = nil, emptyLayer: Bool? = nil) {
            self.created = created; self.createdBy = createdBy; self.author = author; self.comment = comment; self.emptyLayer = emptyLayer
        }
    }
    public init() {}
}
