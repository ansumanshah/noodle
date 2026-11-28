import Foundation
import CFNetwork
import NoodleCore

public struct ProgressEvent: Sendable, Equatable {
    public var id: String?
    public var status: String
    public var current: Int64?
    public var total: Int64?
    public init(id: String? = nil, status: String, current: Int64? = nil, total: Int64? = nil) {
        self.id = id; self.status = status; self.current = current; self.total = total
    }
}
public typealias ProgressHandler = @Sendable (ProgressEvent) -> Void

public struct ManifestResponse: Sendable {
    public var data: Data
    public var mediaType: String
    public var digest: String
}

public struct SearchResult: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var starCount: Int
    public var isOfficial: Bool
    public var isAutomated: Bool
}
