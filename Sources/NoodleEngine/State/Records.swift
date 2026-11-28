import Foundation
import NoodleCore
import NoodleImages

struct EndpointRecord: Codable, Equatable {
    var networkID: String
    var endpointID: String
    var ip: String = ""
    var mac: String = ""
    var aliases: [String] = []
    var staticIP: String?
    var requestedMAC: String?
    var links: [String] = []
    var ip6: String?
    var staticIP6: String?
}

struct ContainerRecord: Codable {
    var id: String
    var name: String                 // without leading slash
    var created: Date
    var image: String                // reference as the user wrote it
    var imageID: String
    var config: ContainerConfig
    var hostConfig: HostConfig
    var status: ContainerStatus = .created
    var pid = 0
    var exitCode = 0
    var error = ""
    var oomKilled = false
    var startedAt: Date?
    var finishedAt: Date?
    var restartCount = 0
    /// Backoff exponent for automatic restarts; back to 0 after a run longer than 10 s. Nil on older records.
    var restartStep: Int?
    var endpoints: [String: EndpointRecord] = [:]       // by network name
    var mounts: [MountPoint] = []
    var guestMounts: [GuestMount] = []
    var ports: [String: [PortBinding]] = [:]            // runtime, "80/tcp" -> host bindings
    var stoppedByUser = false
    var execIDs: [String] = []
    var health: HealthState?
    var primaryNetwork = "bridge"

    var shortID: String { String(id.prefix(12)) }
    var isRunningLike: Bool { status == .running || status == .paused || status == .restarting }
}

struct NetworkRecord: Codable {
    var id: String
    var name: String
    var driver = "bridge"
    var created: Date
    var subnet: String               // CIDR
    var gateway: String
    var ipRange: String?
    var isInternal = false
    var attachable = false
    var enableIPv6 = false
    var labels: [String: String] = [:]
    var options: [String: String] = [:]
    var builtin = false              // bridge, host, none
    var bridgeName: String
    var auxAddresses: [String: String]?
    /// False when the subnet came from the default pools. Nil on records saved before this existed.
    var userSubnet: Bool?
    /// IPv6 half of the pool. `subnet` and `gateway` are empty on an IPv6-only network.
    var subnet6: String?
    var gateway6: String?
    var ipRange6: String?
    var auxAddresses6: [String: String]?
    var userSubnet6: Bool?
}

struct VolumeRecord: Codable {
    var name: String
    var created: Date
    var labels: [String: String] = [:]
    var options: [String: String] = [:]
    var driver = "local"
    var anonymous = false
}

struct EngineState: Codable {
    var containers: [ContainerRecord] = []
    var networks: [NetworkRecord] = []
    var volumes: [VolumeRecord] = []
    var pending: Engine.PendingRemovals?
    var version = 1
}
