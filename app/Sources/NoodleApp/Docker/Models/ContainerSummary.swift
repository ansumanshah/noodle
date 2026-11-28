import Foundation

// Trimmed Docker Engine API shapes. Everything optional that the daemon may omit.

struct PortMapping: Hashable, Sendable, Codable, Identifiable {
    var ip: String?
    var privatePort: Int
    var publicPort: Int?
    var type: String
    var id: String { "\(ip ?? "")|\(privatePort)|\(publicPort ?? 0)|\(type)" }
    enum CodingKeys: String, CodingKey { case ip = "IP", privatePort = "PrivatePort", publicPort = "PublicPort", type = "Type" }
    var url: URL? { publicPort.flatMap { URL(string: "http://localhost:\($0)") } }
}

struct ContainerSummary: Identifiable, Hashable, Sendable, Decodable {
    var id: String
    var names: [String]
    var image: String
    var imageID = ""
    var state: String
    var status: String
    var created: Int
    var ports: [PortMapping]
    var labels: [String: String]
    var sizeRw: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID", state = "State", status = "Status"
        case created = "Created", ports = "Ports", labels = "Labels", sizeRw = "SizeRw"
    }

    init(id: String, names: [String], image: String, state: String, status: String, created: Int,
         ports: [PortMapping] = [], labels: [String: String] = [:], sizeRw: Int? = nil) {
        self.id = id; self.names = names; self.image = image; self.state = state; self.status = status
        self.created = created; self.ports = ports; self.labels = labels; self.sizeRw = sizeRw
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        ports = try c.decodeIfPresent([PortMapping].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        sizeRw = try c.decodeIfPresent(Int.self, forKey: .sizeRw)
    }

    var name: String { (names.first ?? String(id.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var shortID: String { String(id.prefix(12)) }
    var project: String? { labels["com.docker.compose.project"] }
    var service: String? { labels["com.docker.compose.service"] }
    var isRunning: Bool { state == "running" || state == "restarting" || state == "paused" }
    var hasFailed: Bool {
        if state.lowercased() == "dead" { return true }
        guard !isRunning, let range = status.range(of: #"(?i)exited\s*\((-?\d+)\)"#, options: .regularExpression) else { return false }
        let code = status[range].split(separator: "(").last?.dropLast()
        return code.flatMap { Int($0) }.map { $0 != 0 } ?? false
    }
    /// Ports a browser can reach right now: only a running container serves them.
    var openablePorts: [PortMapping] { state == "running" ? publishedPorts : [] }
    var publishedPorts: [PortMapping] {
        var seen = Set<Int>()
        return ports.filter { p in
            guard let pub = p.publicPort else { return false }
            return seen.insert(pub).inserted
        }.sorted { ($0.publicPort ?? 0) < ($1.publicPort ?? 0) }
    }
}

struct ContainerGroup: Identifiable, Hashable, Sendable {
    var project: String?      // nil = standalone containers
    var containers: [ContainerSummary]
    var id: String { project ?? "—standalone" }
    var runningCount: Int { containers.filter(\.isRunning).count }
}

/// Status buckets are mutually exclusive; a failed container is not also stopped.
enum ContainerStatusFilter: String, CaseIterable {
    case all = "All", running = "Running", stopped = "Stopped", failed = "Failed"

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .running: String(localized: "Running")
        case .stopped: String(localized: "Stopped")
        case .failed: String(localized: "Failed")
        }
    }

    /// Whole sentence per filter, so a translation can place the adjective itself.
    var emptyTitle: String {
        switch self {
        case .all: String(localized: "No containers")
        case .running: String(localized: "No running containers")
        case .stopped: String(localized: "No stopped containers")
        case .failed: String(localized: "No failed containers")
        }
    }

    func matches(_ container: ContainerSummary) -> Bool {
        switch self {
        case .all: true
        case .running: container.isRunning
        case .stopped: !container.isRunning && !container.hasFailed
        case .failed: container.hasFailed
        }
    }
}
