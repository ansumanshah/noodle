import Foundation

public struct GuestStats: Codable, Sendable, Equatable {
    public var cpuNs: UInt64 = 0
    public var memory: UInt64 = 0
    public var memoryLimit: UInt64 = 0
    public var pids: UInt64 = 0
    public var netRx: UInt64 = 0
    public var netTx: UInt64 = 0
    public var blkRead: UInt64 = 0
    public var blkWrite: UInt64 = 0
    enum CodingKeys: String, CodingKey {
        case cpuNs = "cpu_ns", memory, memoryLimit = "memory_limit", pids
        case netRx = "net_rx", netTx = "net_tx", blkRead = "blk_read", blkWrite = "blk_write"
    }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuNs = try c.decodeIfPresent(UInt64.self, forKey: .cpuNs) ?? 0
        memory = try c.decodeIfPresent(UInt64.self, forKey: .memory) ?? 0
        memoryLimit = try c.decodeIfPresent(UInt64.self, forKey: .memoryLimit) ?? 0
        pids = try c.decodeIfPresent(UInt64.self, forKey: .pids) ?? 0
        netRx = try c.decodeIfPresent(UInt64.self, forKey: .netRx) ?? 0
        netTx = try c.decodeIfPresent(UInt64.self, forKey: .netTx) ?? 0
        blkRead = try c.decodeIfPresent(UInt64.self, forKey: .blkRead) ?? 0
        blkWrite = try c.decodeIfPresent(UInt64.self, forKey: .blkWrite) ?? 0
    }
}

public struct GuestProcess: Codable, Sendable, Equatable {
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var cmd: String
}

public struct GuestChange: Codable, Sendable, Equatable {
    public var path: String
    /// 0 modified, 1 added, 2 deleted
    public var kind: Int
}

/// Typed wrappers that build requests for the control ops.
public enum GuestRequests {
    public static func create(container: String, spec: ContainerSpec) throws -> (String, [String: JSONValue]) {
        (GuestOp.create, ["container": .string(container), "spec": try JSONValue(encoding: spec)])
    }
}
