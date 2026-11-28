import Foundation
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func containerRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("containers/json") { req, w in
            let filters = try Self.filters(req, allowed: FilterKeys.containers)
            for s in filters["status"] where !FilterKeys.containerStatuses.contains(s) {
                throw EngineError.badRequest("Unrecognised filter value for status: \(s)")
            }
            for h in filters["health"] where !FilterKeys.healthValues.contains(h) {
                throw EngineError.badRequest("Unrecognised filter value for health: \(h)")
            }
            try await w.json(await engine.listContainers(all: req.bool("all"), limit: req.int("limit").flatMap { $0 > 0 ? $0 : nil },
                                                         filters: filters))
        }
        t.post("containers/create") { req, w in
            struct Out: Encodable { var Id: String; var Warnings: [String] }
            var body = try await req.json(ContainerCreateRequest.self) ?? ContainerCreateRequest()
            if let modelConnection, body.hostConfig.DeviceRequests?.contains(where: { $0.Driver == DeviceRequest.modelsDriver }) == true {
                body.config.Env = try await modelConnection().containerEnvironment(adding: body.config.Env ?? [])
            }
            let r = try await engine.createContainer(name: req.string("name"), request: body, platform: req.string("platform"))
            try await w.json(Out(Id: r.id, Warnings: r.warnings), status: .created)
        }
        t.post("containers/prune") { req, w in try await w.json(await engine.pruneContainers(filters: Self.filters(req))) }
        t.post("commit") { req, w in
            struct Out: Encodable { var Id: String }
            let cfg = try await req.json(ContainerConfig.self)
            let id = try await engine.commitContainer(req.string("container") ?? "", repo: req.string("repo"), tag: req.string("tag"),
                                                      comment: req.string("comment") ?? "", author: req.string("author") ?? "",
                                                      changes: req.all("changes"), config: cfg, pause: req.bool("pause", true))
            try await w.json(Out(Id: id), status: .created)
        }
        t.get("containers/{id}/json") { req, w in try await w.json(try await engine.inspectContainer(req.param("id"))) }
        t.get("containers/{id}/top") { req, w in try await w.json(try await engine.top(req.param("id"))) }
        t.get("containers/{id}/changes") { req, w in try await w.json(try await engine.changes(req.param("id"))) }
        t.action(.POST, "containers/{id}/start") { req in try await engine.startContainer(req.param("id")) }
        t.action(.POST, "containers/{id}/stop") { req in
            try await engine.stopContainer(req.param("id"), signal: req.string("signal"), timeout: req.int("t"))
        }
        t.action(.POST, "containers/{id}/restart") { req in
            try await engine.restartContainer(req.param("id"), signal: req.string("signal"), timeout: req.int("t"))
        }
        t.action(.POST, "containers/{id}/kill") { req in try await engine.killContainer(req.param("id"), signal: req.string("signal")) }
        t.action(.POST, "containers/{id}/pause") { req in try await engine.pauseContainer(req.param("id")) }
        t.action(.POST, "containers/{id}/unpause") { req in try await engine.unpauseContainer(req.param("id")) }
        t.action(.POST, "containers/{id}/rename") { req in
            guard let name = req.string("name"), !name.isEmpty else { throw APIError(status: 400, message: "name is required") }
            try await engine.renameContainer(req.param("id"), to: name)
        }
        t.post("containers/{id}/update") { req, w in
            struct Out: Encodable { var Warnings: [String] }
            let u = try await req.json(ContainerUpdateRequest.self) ?? ContainerUpdateRequest()
            try await w.json(Out(Warnings: try await engine.updateContainer(req.param("id"), u)))
        }
        t.action(.POST, "containers/{id}/resize", status: .ok) { req in
            try await engine.resizeContainer(req.param("id"), rows: req.int("h") ?? 0, cols: req.int("w") ?? 0)
        }
        t.post("containers/{id}/wait") { req, w in
            struct ErrBody: Encodable { var Message: String }
            struct Out: Encodable { var StatusCode: Int; var Error: ErrBody? }
            let id = req.param("id")
            _ = try await engine.inspectContainer(id)   // 404 before the stream starts
            try await w.beginStream(contentType: Self.jsonStream)
            let r = try await engine.waitContainer(id, condition: req.string("condition") ?? "not-running")
            try await w.writeJSON(Out(StatusCode: r.StatusCode, Error: r.Error.map { ErrBody(Message: $0) }))
        }
        t.action(.DELETE, "containers/{id}") { req in
            try await engine.removeContainer(req.param("id"), force: req.bool("force"), removeVolumes: req.bool("v"))
        }
    }
}
