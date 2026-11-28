import Foundation

// MARK: - Container spec (docs/architecture/protocol.md "Container spec")

public struct GuestMount: Codable, Sendable, Equatable {
    public var kind: String          // bind | volume | tmpfs
    public var source: String
    public var target: String
    public var readOnly: Bool
    public var tmpfsSize: Int64
    public var noCopy: Bool?
    enum CodingKeys: String, CodingKey { case kind, source, target, readOnly = "read_only", tmpfsSize = "tmpfs_size", noCopy = "no_copy" }
    public init(kind: String, source: String = "", target: String, readOnly: Bool = false, tmpfsSize: Int64 = 0, noCopy: Bool = false) {
        self.kind = kind; self.source = source; self.target = target; self.readOnly = readOnly; self.tmpfsSize = tmpfsSize; self.noCopy = noCopy
    }
}

public struct GuestNetwork: Codable, Sendable, Equatable {
    public var name: String
    public var ip: String
    public var gateway: String
    public var prefix: Int
    public var mac: String
    public var ip6: String?
    public var prefix6: Int?
    public var gateway6: String?
    public init(name: String, ip: String, gateway: String, prefix: Int, mac: String = "") {
        self.name = name; self.ip = ip; self.gateway = gateway; self.prefix = prefix; self.mac = mac
    }
}

public struct GuestUlimit: Codable, Sendable, Equatable {
    public var name: String
    public var soft: Int64
    public var hard: Int64
    public init(name: String, soft: Int64, hard: Int64) { self.name = name; self.soft = soft; self.hard = hard }
}

/// The embedded DNS server for a container on a user network: its `--dns` servers and links.
public struct GuestResolver: Codable, Sendable, Equatable {
    public struct Link: Codable, Sendable, Equatable {
        public var alias: String
        public var target: String
        public init(alias: String, target: String) { self.alias = alias; self.target = target }
    }
    public var servers: [String]
    public var links: [Link]
    public init(servers: [String] = [], links: [Link] = []) { self.servers = servers; self.links = links }
}
