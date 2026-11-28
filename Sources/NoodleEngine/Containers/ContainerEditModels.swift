import Foundation
import NoodleCore

public struct ContainerEditRequest: Codable, Sendable {
    public var env: [String] = []
    public var unsetEnv: [String] = []
    public var publish: [String] = []
    public var unpublish: [String] = []
    public var dryRun = false
    public var restart = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case env, unsetEnv, publish, unpublish, dryRun, restart }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        env = try c.decodeIfPresent([String].self, forKey: .env) ?? []
        unsetEnv = try c.decodeIfPresent([String].self, forKey: .unsetEnv) ?? []
        publish = try c.decodeIfPresent([String].self, forKey: .publish) ?? []
        unpublish = try c.decodeIfPresent([String].self, forKey: .unpublish) ?? []
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        restart = try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false
    }
}

public struct ContainerEditResult: Codable, Sendable {
    public var message: String
}

public struct ContainerListeningPort: Codable, Sendable {
    public var port: Int
    public var `protocol`: String
    public var address: String
    public var process: String?
    public var published: [PortBinding]
}
