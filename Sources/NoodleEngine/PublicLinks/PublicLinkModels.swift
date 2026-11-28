import Foundation
import NoodleCore

public struct PublicLinkTarget: Codable, Sendable {
    public var containerID: String
    public var containerName: String
    public var containerIP: String
    public var containerPort: Int
    /// What the published app can reach beyond itself. The CLI prints these before asking for consent.
    public var warnings: [String] = []
}

public struct PublicLinkStatus: Codable, Sendable {
    public var id: String
    public var containerID: String
    public var containerName: String
    public var containerIP: String
    public var containerPort: Int
    public var target: String
    public var url: String?
    public var state: String
    public var detail: String?
    public var pid: Int32?
}
