import Foundation
import NoodleCore

// Wire models. Property names equal Docker's JSON keys on purpose (`Id`, `HostConfig`, ...), so the API layer can
// decode request bodies and encode responses with a plain JSONEncoder/JSONDecoder, no key mapping.
// Decoding is lenient: missing or null fields fall back to defaults, as the Docker daemon does.

extension KeyedDecodingContainer {
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? fallback }
    func opt<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
}

public struct EmptyStruct: Codable, Sendable, Equatable, Hashable { public init() {} }

public struct PortBinding: Codable, Sendable, Equatable, Hashable {
    public var HostIp: String
    public var HostPort: String
    public init(HostIp: String = "", HostPort: String = "") { self.HostIp = HostIp; self.HostPort = HostPort }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        HostIp = c.get(.HostIp, ""); HostPort = c.get(.HostPort, "")
    }
}

public struct HealthConfig: Codable, Sendable, Equatable {
    public var Test: [String]?
    public var Interval: Int64?
    public var Timeout: Int64?
    public var StartPeriod: Int64?
    public var StartInterval: Int64?
    public var Retries: Int?
    public init() {}
}

public struct ContainerConfig: Codable, Sendable, Equatable {
    public var Hostname = ""
    public var Domainname = ""
    public var User = ""
    public var AttachStdin = false
    public var AttachStdout = false
    public var AttachStderr = false
    public var ExposedPorts: [String: EmptyStruct]?
    public var Tty = false
    public var OpenStdin = false
    public var StdinOnce = false
    public var Env: [String]?
    public var Cmd: [String]?
    public var Healthcheck: HealthConfig?
    public var Image = ""
    public var Volumes: [String: EmptyStruct]?
    public var WorkingDir = ""
    public var Entrypoint: [String]?
    public var NetworkDisabled: Bool?
    public var MacAddress: String?
    public var Labels: [String: String]?
    public var StopSignal: String?
    public var StopTimeout: Int?
    public var Shell: [String]?

    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        Hostname = c.get(.Hostname, ""); Domainname = c.get(.Domainname, ""); User = c.get(.User, "")
        AttachStdin = c.get(.AttachStdin, false); AttachStdout = c.get(.AttachStdout, false); AttachStderr = c.get(.AttachStderr, false)
        ExposedPorts = c.opt(.ExposedPorts); Tty = c.get(.Tty, false); OpenStdin = c.get(.OpenStdin, false); StdinOnce = c.get(.StdinOnce, false)
        Env = c.opt(.Env); Cmd = Self.stringOrArray(c, .Cmd); Healthcheck = c.opt(.Healthcheck); Image = c.get(.Image, "")
        Volumes = c.opt(.Volumes); WorkingDir = c.get(.WorkingDir, ""); Entrypoint = Self.stringOrArray(c, .Entrypoint)
        NetworkDisabled = c.opt(.NetworkDisabled); MacAddress = c.opt(.MacAddress); Labels = c.opt(.Labels)
        StopSignal = c.opt(.StopSignal); StopTimeout = c.opt(.StopTimeout); Shell = c.opt(.Shell)
    }
    /// Docker accepts `"Cmd": "echo hi"` as a single-element command.
    private static func stringOrArray<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> [String]? {
        if let a: [String] = c.opt(k) { return a }
        if let s: String = c.opt(k) { return [s] }
        return nil
    }
}

public struct LogConfig: Codable, Sendable, Equatable {
    public var `Type` = "json-file"
    public var Config: [String: String]?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        `Type` = c.get(.Type, "json-file"); Config = c.opt(.Config)
    }
}

public struct RestartPolicy: Codable, Sendable, Equatable {
    public var Name = ""
    public var MaximumRetryCount = 0
    public init() {}
    public init(Name: String, MaximumRetryCount: Int = 0) { self.Name = Name; self.MaximumRetryCount = MaximumRetryCount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        Name = c.get(.Name, ""); MaximumRetryCount = c.get(.MaximumRetryCount, 0)
    }
}

public struct MountConfig: Codable, Sendable, Equatable {
    public struct BindOpts: Codable, Sendable, Equatable { public var Propagation: String?; public var CreateMountpoint: Bool? }
    public struct VolumeOpts: Codable, Sendable, Equatable { public var NoCopy: Bool?; public var Labels: [String: String]? }
    public struct TmpfsOpts: Codable, Sendable, Equatable { public var SizeBytes: Int64?; public var Mode: Int? }
    public var `Type` = "volume"
    public var Source = ""
    public var Target = ""
    public var ReadOnly = false
    public var Consistency: String?
    public var BindOptions: BindOpts?
    public var VolumeOptions: VolumeOpts?
    public var TmpfsOptions: TmpfsOpts?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        `Type` = c.get(.Type, "volume"); Source = c.get(.Source, ""); Target = c.get(.Target, ""); ReadOnly = c.get(.ReadOnly, false)
        Consistency = c.opt(.Consistency); BindOptions = c.opt(.BindOptions); VolumeOptions = c.opt(.VolumeOptions); TmpfsOptions = c.opt(.TmpfsOptions)
    }
}

public struct Ulimit: Codable, Sendable, Equatable { public var Name = ""; public var Soft: Int64 = 0; public var Hard: Int64 = 0 }

public struct DeviceMapping: Codable, Sendable, Equatable {
    public var PathOnHost = ""
    public var PathInContainer = ""
    public var CgroupPermissions = ""
}
