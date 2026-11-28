import Foundation
import NoodleEngine

extension Handlers {
    func devRoutes(_ table: inout RouteTable) {
        let engine = self.engine
        table.post("noodle/dev") { request, writer in
            struct Registration: Decodable { let host: String; let port: Int; let ownerPID: Int32 }
            let input = try await request.decode(Registration.self, limit: 4096, invalid: "Expected host, port and ownerPID.")
            try await writer.json(try await engine.registerDev(host: input.host, port: input.port, ownerPID: input.ownerPID))
        }
        table.post("noodle/names/host") { request, writer in
            struct Input: Decodable { let name: String; let port: Int }
            let input = try await request.decode(Input.self, limit: 4096, invalid: "Expected name and port.")
            try await writer.json(try await engine.addHostName(input.name, port: input.port))
        }
        table.delete("noodle/names/host/{name}") { request, writer in
            try await engine.removeHostName(request.param("name"))
            try await writer.empty()
        }
        table.delete("noodle/dev/{token}") { request, writer in
            await engine.unregisterDev(token: request.param("token"))
            try await writer.empty()
        }
    }
}
