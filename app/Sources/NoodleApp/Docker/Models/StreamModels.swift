import Foundation

struct DockerEvent: Decodable, Sendable {
    var type: String
    var action: String
    var actorID: String?
    var actorName: String?
    enum CodingKeys: String, CodingKey { case type = "Type", action = "Action", actor = "Actor" }
    struct Actor: Decodable {
        var id: String?
        var name: String?
        enum CodingKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            name = (try? values.decode([String: String].self, forKey: .attributes))?["name"]
        }
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        let actor = try c.decodeIfPresent(Actor.self, forKey: .actor)
        actorID = actor?.id
        actorName = actor?.name
    }
}

struct StatsSample: Identifiable, Hashable, Sendable {
    var id: Int
    var cpuPercent: Double
    var memoryBytes: Int
    var memoryLimit: Int
    var netRx: Int
    var netTx: Int
    var pids: Int
}
