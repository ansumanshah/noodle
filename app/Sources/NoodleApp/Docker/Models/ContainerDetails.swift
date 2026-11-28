import Foundation

struct ContainerDetails: Hashable, Sendable, Decodable {
    struct State: Hashable, Sendable, Decodable {
        var status: String?; var running: Bool?; var pid: Int?; var exitCode: Int?; var startedAt: String?; var finishedAt: String?
        enum CodingKeys: String, CodingKey { case status = "Status", running = "Running", pid = "Pid", exitCode = "ExitCode", startedAt = "StartedAt", finishedAt = "FinishedAt" }
    }
    struct Config: Hashable, Sendable, Decodable {
        var image: String?; var cmd: [String]?; var entrypoint: [String]?; var env: [String]?; var tty: Bool?; var workingDir: String?; var user: String?
        enum CodingKeys: String, CodingKey { case image = "Image", cmd = "Cmd", entrypoint = "Entrypoint", env = "Env", tty = "Tty", workingDir = "WorkingDir", user = "User" }
    }
    struct Mount: Hashable, Sendable, Decodable, Identifiable {
        var type: String?; var source: String?; var destination: String?; var name: String?; var rw: Bool?
        var id: String { (destination ?? "") + (source ?? "") }
        /// The Mac folder behind a bind mount. Named volumes live inside the VM, so they have none.
        var hostFolder: URL? {
            guard type == "bind", let source, source.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: source)
        }
        enum CodingKeys: String, CodingKey { case type = "Type", source = "Source", destination = "Destination", name = "Name", rw = "RW" }
    }
    struct Net: Hashable, Sendable, Decodable {
        var ipAddress: String?; var gateway: String?; var macAddress: String?
        enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress", gateway = "Gateway", macAddress = "MacAddress" }
    }
    struct NetworkSettings: Hashable, Sendable, Decodable {
        var networks: [String: Net]?
        enum CodingKeys: String, CodingKey { case networks = "Networks" }
    }
    struct HostConfig: Hashable, Sendable, Decodable {
        var memory: Int?; var nanoCpus: Int?
        enum CodingKeys: String, CodingKey { case memory = "Memory", nanoCpus = "NanoCpus" }
    }
    var id: String
    var name: String?
    var created: String?
    var state: State?
    var config: Config?
    var mounts: [Mount]?
    var networkSettings: NetworkSettings?
    var hostConfig: HostConfig?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", created = "Created", state = "State", config = "Config"
        case mounts = "Mounts", networkSettings = "NetworkSettings", hostConfig = "HostConfig"
    }
    var command: String { ((config?.entrypoint ?? []) + (config?.cmd ?? [])).joined(separator: " ") }
}
