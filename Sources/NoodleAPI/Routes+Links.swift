import Foundation
import NoodleEngine

extension Handlers {
    private struct PublicLinkRequest: Decodable {
        var container: String
        var port: Int?
        var confirmed: Bool?
        var allowPrivileged: Bool?
    }

    private struct PublicLinkStopRequest: Decodable {
        var id: String
    }

    func publicLinkRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("noodle/links") { _, w in
            try await w.json(await engine.publicLinks())
        }
        t.post("noodle/links/target") { req, w in
            let request = try await req.decode(PublicLinkRequest.self, limit: 16 << 10)
            try await w.json(try await engine.publicLinkTarget(request.container, port: request.port,
                                                             allowPrivileged: request.allowPrivileged ?? false))
        }
        t.post("noodle/links") { req, w in
            let request = try await req.decode(PublicLinkRequest.self, limit: 16 << 10)
            try await w.json(try await engine.startPublicLink(request.container, port: request.port,
                                                            confirmed: request.confirmed ?? false,
                                                            allowPrivileged: request.allowPrivileged ?? false))
        }
        t.post("noodle/links/stop") { req, w in
            let request = try await req.decode(PublicLinkStopRequest.self, limit: 16 << 10)
            try await engine.stopPublicLink(request.id)
            try await w.json([String: String]())
        }
    }
}
