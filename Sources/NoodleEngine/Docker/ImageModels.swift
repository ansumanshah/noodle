import Foundation
import NoodleCore

public struct ImageSummary: Codable, Sendable, Equatable {
    public var Id = ""
    public var ParentId = ""
    public var RepoTags: [String] = []
    public var RepoDigests: [String] = []
    public var Created: Int64 = 0
    public var Size: Int64 = 0
    public var SharedSize: Int64 = -1
    public var VirtualSize: Int64 = 0
    public var Labels: [String: String] = [:]
    public var Containers: Int = -1
    public init() {}
}

public struct ImageInspect: Codable, Sendable, Equatable {
    public struct RootFS: Codable, Sendable, Equatable { public var `Type` = "layers"; public var Layers: [String] = []; public init() {} }
    public struct Metadata: Codable, Sendable, Equatable { public var LastTagTime = "0001-01-01T00:00:00Z"; public init() {} }
    public var Id = ""
    public var RepoTags: [String] = []
    public var RepoDigests: [String] = []
    public var Parent = ""
    public var Comment = ""
    public var Created = ""
    public var DockerVersion = ""
    public var Author = ""
    public var Config = ContainerConfig()
    public var Architecture = "arm64"
    public var Variant: String?
    public var Os = "linux"
    public var Size: Int64 = 0
    public var VirtualSize: Int64 = 0
    public var GraphDriver = NoodleEngine.GraphDriver()
    public var RootFS = ImageInspect.RootFS()
    public var Metadata = ImageInspect.Metadata()
    public init() {}
}

public struct ImageHistoryEntry: Codable, Sendable, Equatable {
    public var Id: String
    public var Created: Int64
    public var CreatedBy: String
    public var Tags: [String]
    public var Size: Int64
    public var Comment: String
}

public struct ImageDeleteItem: Codable, Sendable, Equatable {
    public var Untagged: String?
    public var Deleted: String?
}

public struct ImagePruneResponse: Codable, Sendable { public var ImagesDeleted: [ImageDeleteItem] = []; public var SpaceReclaimed: Int64 = 0 }
public struct ContainerPruneResponse: Codable, Sendable { public var ContainersDeleted: [String] = []; public var SpaceReclaimed: Int64 = 0 }
public struct VolumePruneResponse: Codable, Sendable { public var VolumesDeleted: [String] = []; public var SpaceReclaimed: Int64 = 0 }
public struct NetworkPruneResponse: Codable, Sendable { public var NetworksDeleted: [String] = [] }
