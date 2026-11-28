import Foundation
import OSLog
@_exported import NoodleCore
@_exported import NoodleImages
@_exported import NoodleVM

struct ExecRecord {
    var id: String
    var containerID: String
    var config: ExecConfig
    var running = false
    var exitCode: Int?
    var pid = 0
    var stream: GuestStream?
    var finished: Date?
}

public struct WaitResult: Sendable, Equatable {
    public var StatusCode: Int
    public var Error: String?
}

public struct VMStatus: Codable, Sendable, Equatable {
    public struct Usage: Codable, Sendable, Equatable {
        public var cpus: Int
        public var memoryMiB: Int
        public var memoryUsed: UInt64?
        public var cpuBusy: UInt64?
        public var cpuTotal: UInt64?
    }
    public var state: String
    public var vmRunning: Bool
    public var guestAgentReady: Bool
    public var cpus: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    public var lastBootMilliseconds: Int?
    public var bootCount: Int
    public var usage: Usage?
}
