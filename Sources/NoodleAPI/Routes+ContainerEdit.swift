import Foundation
import NoodleEngine

extension Handlers {
    func containerEditRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.post("containers/{id}/noodle/edit") { req, w in
            guard let request = try await req.json(ContainerEditRequest.self) else {
                throw EngineError.badRequest("container edit requires a JSON request")
            }
            try await w.json(try await engine.editContainer(req.param("id"), request: request))
        }
        t.get("containers/{id}/noodle/ports") { req, w in
            try await w.json(try await engine.containerListeningPorts(req.param("id")))
        }
    }
}
