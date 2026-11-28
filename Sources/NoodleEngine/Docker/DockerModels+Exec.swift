import Foundation
import NoodleCore

// MARK: exec

public struct ExecConfig: Codable, Sendable, Equatable {
    public var AttachStdin = false
    public var AttachStdout = true
    public var AttachStderr = true
    public var DetachKeys = ""
    public var Tty = false
    public var Env: [String]?
    public var Cmd: [String] = []
    public var Privileged = false
    public var User = ""
    public var WorkingDir = ""
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        AttachStdin = c.get(.AttachStdin, false); AttachStdout = c.get(.AttachStdout, true); AttachStderr = c.get(.AttachStderr, true)
        DetachKeys = c.get(.DetachKeys, ""); Tty = c.get(.Tty, false); Env = c.opt(.Env)
        Cmd = (try? c.decodeIfPresent([String].self, forKey: .Cmd)) ?? ((try? c.decodeIfPresent(String.self, forKey: .Cmd)).flatMap { $0 }.map { [$0] }) ?? []
        Privileged = c.get(.Privileged, false); User = c.get(.User, ""); WorkingDir = c.get(.WorkingDir, "")
    }
}

public struct ExecInspect: Codable, Sendable, Equatable {
    public struct ProcessConfig: Codable, Sendable, Equatable {
        public var arguments: [String] = []
        public var entrypoint = ""
        public var privileged = false
        public var tty = false
        public var user = ""
        public init() {}
    }
    public var CanRemove = false
    public var ContainerID = ""
    public var DetachKeys = ""
    public var ExitCode: Int?
    public var ID = ""
    public var OpenStderr = true
    public var OpenStdin = false
    public var OpenStdout = true
    public var ProcessConfig = ExecInspect.ProcessConfig()
    public var Running = false
    public var Pid = 0
    public init() {}
}

public struct ContainerUpdateRequest: Codable, Sendable, Equatable {
    public var Memory: Int64?
    public var MemorySwap: Int64?
    public var NanoCpus: Int64?
    public var CpuShares: Int64?
    public var CpuQuota: Int64?
    public var CpuPeriod: Int64?
    public var PidsLimit: Int64?
    public var CpusetCpus: String?
    public var CpusetMems: String?
    public var RestartPolicy: RestartPolicy?
    public init() {}
}

public struct TopResult: Codable, Sendable, Equatable {
    public var Titles: [String]
    public var Processes: [[String]]
}

public struct FsChange: Codable, Sendable, Equatable {
    public var Path: String
    public var Kind: Int      // 0 modified, 1 added, 2 deleted
}
