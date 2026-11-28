import Foundation

struct ImageSummary: Identifiable, Hashable, Sendable, Decodable {
    var id: String
    var repoTags: [String]
    var size: Int
    var created: Int
    var containers: Int
    enum CodingKeys: String, CodingKey { case id = "Id", repoTags = "RepoTags", size = "Size", created = "Created", containers = "Containers" }
    init(id: String, repoTags: [String], size: Int, created: Int, containers: Int = 0) {
        self.id = id; self.repoTags = repoTags; self.size = size; self.created = created; self.containers = containers
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        containers = max(0, try c.decodeIfPresent(Int.self, forKey: .containers) ?? 0)
    }
    var displayName: String { repoTags.first ?? "<untagged>" }
    var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
}

struct VolumeSummary: Identifiable, Hashable, Sendable, Decodable {
    var name: String
    var driver: String
    var mountpoint: String
    var createdAt: String?
    var id: String { name }
    enum CodingKeys: String, CodingKey { case name = "Name", driver = "Driver", mountpoint = "Mountpoint", createdAt = "CreatedAt" }
    init(name: String, driver: String = "local", mountpoint: String = "", createdAt: String? = nil) {
        self.name = name; self.driver = driver; self.mountpoint = mountpoint; self.createdAt = createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "local"
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct NetworkSummary: Identifiable, Hashable, Sendable, Decodable {
    var id: String
    var name: String
    var driver: String
    var scope: String
    var subnet: String?
    var attached: Int
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", driver = "Driver", scope = "Scope", ipam = "IPAM", containers = "Containers" }
    struct IPAM: Decodable { var config: [Cfg]?; struct Cfg: Decodable { var subnet: String?; enum CodingKeys: String, CodingKey { case subnet = "Subnet" } }
        enum CodingKeys: String, CodingKey { case config = "Config" } }
    struct Anything: Decodable {}
    init(id: String, name: String, driver: String, scope: String = "local", subnet: String? = nil, attached: Int = 0) {
        self.id = id; self.name = name; self.driver = driver; self.scope = scope; self.subnet = subnet; self.attached = attached
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        subnet = try c.decodeIfPresent(IPAM.self, forKey: .ipam)?.config?.first?.subnet
        attached = (try c.decodeIfPresent([String: Anything].self, forKey: .containers))?.count ?? 0
    }
    /// Built-in networks can't be removed.
    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
}

struct ImageHistory: Decodable, Sendable {
    let identity = UUID()
    let id: String
    let created: Int
    let createdBy: String
    let size: Int
    enum CodingKeys: String, CodingKey { case id = "Id", created = "Created", createdBy = "CreatedBy", size = "Size" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}
