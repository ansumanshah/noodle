import Foundation

struct DaemonInfo: Hashable, Sendable, Decodable {
    var name: String
    var ncpu: Int
    var memTotal: Int
    var kernelVersion: String
    var operatingSystem: String
    var serverVersion: String
    var architecture: String
    var containersRunning: Int
    enum CodingKeys: String, CodingKey {
        case name = "Name", ncpu = "NCPU", memTotal = "MemTotal", kernelVersion = "KernelVersion"
        case operatingSystem = "OperatingSystem", serverVersion = "ServerVersion", architecture = "Architecture"
        case containersRunning = "ContainersRunning"
    }
    init(name: String, ncpu: Int, memTotal: Int, kernelVersion: String, operatingSystem: String, serverVersion: String, architecture: String, containersRunning: Int) {
        self.name = name; self.ncpu = ncpu; self.memTotal = memTotal; self.kernelVersion = kernelVersion
        self.operatingSystem = operatingSystem; self.serverVersion = serverVersion; self.architecture = architecture
        self.containersRunning = containersRunning
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "noodle"
        ncpu = try c.decodeIfPresent(Int.self, forKey: .ncpu) ?? 0
        memTotal = try c.decodeIfPresent(Int.self, forKey: .memTotal) ?? 0
        kernelVersion = try c.decodeIfPresent(String.self, forKey: .kernelVersion) ?? ""
        operatingSystem = try c.decodeIfPresent(String.self, forKey: .operatingSystem) ?? ""
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? ""
        containersRunning = try c.decodeIfPresent(Int.self, forKey: .containersRunning) ?? 0
    }
}
