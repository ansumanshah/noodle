import Foundation
import NoodleCore

extension Engine {
    public func containerListeningPorts(_ ref: String) async throws -> [ContainerListeningPort] {
        let id = try resolveContainerID(ref)
        return try await withLock(id) {
            guard let c = containers[id], c.status == .running || c.status == .paused else {
                throw EngineError.conflict("Container \(ref) is not running")
            }
            let result = try await runtime(for: c).guest.call(GuestOp.listPorts, ["container": .string(id)], boot: false)
            struct Reply: Decodable {
                struct Port: Decodable { var port: Int; var `protocol`: String; var address: String; var process: String? }
                var ports: [Port]
            }
            let reply = try JSONDecoder().decode(Reply.self, from: JSONEncoder().encode(JSONValue.object(result)))
            return reply.ports.map { p in
                ContainerListeningPort(port: p.port, protocol: p.protocol, address: p.address, process: p.process,
                                       published: c.ports["\(p.port)/\(p.protocol)"] ?? [])
            }
        }
    }
}
