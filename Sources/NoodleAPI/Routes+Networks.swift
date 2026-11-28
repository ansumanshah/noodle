import Foundation
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func networkRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("networks") { req, w in try await w.json(await engine.listNetworks(filters: try Self.filters(req, allowed: FilterKeys.networks))) }
        t.post("networks/create") { req, w in
            struct Out: Encodable { var Id: String; var Warning: String }
            let body = try await req.json(NetworkCreateRequest.self) ?? NetworkCreateRequest()
            let r = try await engine.createNetwork(body)
            try await w.json(Out(Id: r.id, Warning: r.warning), status: .created)
        }
        t.post("networks/prune") { req, w in try await w.json(await engine.pruneNetworks(filters: Self.filters(req))) }
        t.get("networks/{id}") { req, w in try await w.json(try await engine.inspectNetwork(req.param("id"))) }
        t.action(.DELETE, "networks/{id}") { req in try await engine.removeNetwork(req.param("id")) }
        t.action(.POST, "networks/{id}/connect", status: .ok) { req in
            let b = try await req.json(NetworkConnectRequest.self) ?? NetworkConnectRequest()
            try await engine.connectNetwork(req.param("id"), container: b.Container, endpoint: b.EndpointConfig)
        }
        t.action(.POST, "networks/{id}/disconnect", status: .ok) { req in
            struct B: Decodable { var Container: String?; var Force: Bool? }
            let b = try await req.json(B.self)
            try await engine.disconnectNetwork(req.param("id"), container: b?.Container ?? "")
        }
    }

    func volumeRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("volumes") { req, w in
            struct Out: Encodable { var Volumes: [Volume]; var Warnings: [String] }
            try await w.json(Out(Volumes: await engine.listVolumes(filters: try Self.filters(req, allowed: FilterKeys.volumes)), Warnings: []))
        }
        t.post("volumes/create") { req, w in
            let b = try await req.json(VolumeCreateRequest.self) ?? VolumeCreateRequest()
            try await w.json(try await engine.createVolume(b), status: .created)
        }
        t.post("volumes/prune") { req, w in
            let f = Self.filters(req)
            try await w.json(await engine.pruneVolumes(filters: f, all: f.bool("all") ?? false))
        }
        t.get("volumes/{name}") { req, w in try await w.json(try await engine.inspectVolume(req.param("name"))) }
        t.action(.DELETE, "volumes/{name}") { req in try await engine.removeVolume(req.param("name"), force: req.bool("force")) }
    }
}
