import Foundation
import NIOCore
import NIOHTTP1
import NoodleEngine
import NoodleImages

extension Handlers {
    func systemRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("_ping") { _, w in
            try await w.send(.ok, contentType: "text/plain; charset=utf-8", headers: [
                ("Cache-Control", "no-cache, no-store, must-revalidate"), ("Pragma", "no-cache"),
                ("Builder-Version", "2"), ("Swarm", "inactive")], body: ByteBuffer(string: "OK"))
        }
        t.get("version") { _, w in try await w.json(await engine.version()) }
        t.get("info") { _, w in try await w.json(await engine.info()) }
        t.get("noodle/vm/status") { req, w in try await w.json(await engine.vmStatus(includeUsage: req.bool("usage"))) }
        t.get("noodle/names") { _, w in try await w.json(await engine.namesStatus()) }
        t.get("system/df") { _, w in try await w.json(await engine.diskUsage()) }
        t.get("events") { req, w in
            let events = await engine.events(since: req.seconds("since"), until: req.seconds("until"), filters: Self.filters(req))
            try await w.beginStream(contentType: Self.jsonStream)
            for await e in events { try await w.writeJSON(e) }
        }
        t.post("auth") { req, w in
            struct Auth: Decodable { var username: String?; var password: String?; var serveraddress: String?; var identitytoken: String? }
            let a = try await req.decode(Auth.self, limit: 1 << 20)
            guard let server = a.serveraddress, !server.isEmpty else { throw APIError(status: 400, message: "serveraddress is required") }
            try await engine.registryLogin(serverAddress: server, username: a.username, password: a.password, identityToken: a.identitytoken)
            struct Out: Encodable { var Status = "Login Succeeded"; var IdentityToken = "" }
            try await w.json(Out())
        }
        t.get("noodle/kubernetes/shared-folders") { _, w in try await w.json(await engine.workloadSharedFolders()) }
        t.post("noodle/kubernetes/shared-folders") { req, w in
            let s = try await req.decode(Engine.SharedFolders.self, limit: 1 << 10)
            guard let on = s.Enabled else { throw APIError(status: 400, message: "Enabled is required") }
            try await w.json(try await engine.setWorkloadSharedFolders(on, forceRestart: s.Restart == true))
        }
        t.get("noodle/proxy") { _, w in try await w.json(await engine.proxySettings()) }
        t.post("noodle/proxy") { req, w in
            let s = try await req.decode(ProxySettings.self, limit: 1 << 20)
            try await engine.setProxySettings(s)
            try await w.json(await engine.proxySettings())
        }
        t.get("distribution/*name/json") { req, w in try await w.json(try await distribution(req)) }
        t.get("plugins") { _, w in try await w.json([String]()) }
        t.post("build") { req, w in try await build(req, w) }
        t.post("noodle/buildkit/import") { req, w in
            struct Output: Decodable { let File: String; let Digest: String; let Tags: [String]? }
            guard let token = req.headers.first(name: "X-Noodle-Build-Token"), token.count == 36 else {
                throw APIError(status: 403, message: "missing build capability")
            }
            let output = try await req.decode(Output.self, limit: 64 << 10, invalid: "invalid worker output")
            let id = try await engine.importNativeImage(token: token, file: output.File, digest: output.Digest, tags: output.Tags ?? [])
            try await w.json(["ID": id])
        }
        t.post("noodle/buildkit/history") { req, w in try await nativeBuildHistory(req, w) }
        buildBaseRoutes(&t)
        for p in ["session", "grpc"] {
            t.post(p) { req, w in try await nativeBuildConnection(req, w, mode: p) }
        }
        for p in ["swarm", "nodes", "services", "tasks", "secrets", "configs", "nodes/{id}", "services/{id}", "tasks/{id}", "secrets/{id}", "configs/{id}"] {
            t.get(p) { _, _ in try await notSwarm() }
        }
        t.post("swarm/init") { _, _ in try await notSwarm() }
        t.post("swarm/join") { _, _ in try await notSwarm() }
    }

    // MARK: - distribution inspect

    struct DistributionInspect: Encodable {
        struct Descriptor: Encodable { var mediaType: String; var digest: String; var size: Int64 }
        struct Platform: Encodable { var architecture: String; var os: String; var variant: String? }
        var Descriptor: Descriptor
        var Platforms: [Platform]
    }

    func distribution(_ req: Request) async throws -> DistributionInspect {
        let name = req.param("name")
        let registry = engine.imageStore.registry
        let ref: ImageReference
        do { ref = try ImageReference.parse(name) } catch { throw APIError(status: 400, message: "invalid reference format: \(name)") }
        let top: ManifestResponse
        do { top = try await registry.manifest(ref, credential: Engine.decodeRegistryAuth(req.headers.first(name: "X-Registry-Auth"))) } catch {
            throw APIError(status: 401, message: "manifest unavailable for \(name): \(error)")
        }
        var platforms: [DistributionInspect.Platform] = []
        if MediaType.isIndex(top.mediaType), let m = try? JSONDecoder().decode(Manifest.self, from: top.data) {
            platforms = (m.manifests ?? []).compactMap { d in
                d.platform.map { .init(architecture: $0.architecture, os: $0.os, variant: $0.variant) }
            }
        } else {
            platforms = [.init(architecture: "arm64", os: "linux", variant: "v8")]
        }
        return DistributionInspect(Descriptor: .init(mediaType: top.mediaType, digest: top.digest, size: Int64(top.data.count)), Platforms: platforms)
    }
}
