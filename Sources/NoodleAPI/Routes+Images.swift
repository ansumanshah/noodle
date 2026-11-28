import Foundation
import NIOCore
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func imageRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.get("images/json") { req, w in
            try await w.json(await engine.listImages(all: req.bool("all"), filters: try Self.filters(req, allowed: FilterKeys.images)))
        }
        t.post("images/create") { req, w in
            let auth = req.headers.first(name: "X-Registry-Auth")
            if let src = req.string("fromSrc"), !src.isEmpty {
                guard src == "-" else { throw APIError(status: 400, message: "importing from a URL is not supported; pipe a tarball with fromSrc=-") }
                let spool = try await spoolBody(req)
                defer { spool.remove() }
                let img = try await engine.importImage(from: spool.url, repo: req.string("repo"), tag: req.string("tag"),
                                                       message: req.string("message") ?? "", changes: req.all("changes"), platform: req.string("platform"))
                struct Out: Encodable { var status: String }
                try await w.json(Out(status: img.id))
                return
            }
            guard let from = req.string("fromImage"), !from.isEmpty else { throw APIError(status: 400, message: "fromImage or fromSrc is required") }
            try await streamProgress(await engine.pullImage(from, tag: req.string("tag"), platform: req.string("platform"), registryAuth: auth), w)
        }
        t.get("images/search") { req, w in
            try await w.json(try await engine.searchImages(term: req.string("term") ?? "", limit: req.int("limit") ?? 25, filters: Self.filters(req)))
        }
        t.post("images/prune") { req, w in try await w.json(try await engine.pruneImages(filters: Self.filters(req))) }
        t.post("images/load") { req, w in
            let spool = try await spoolBody(req)
            defer { spool.remove() }
            let loaded = try await engine.loadImages(from: spool.url)
            struct Line: Encodable { var stream: String }
            try await w.beginStream(contentType: Self.jsonStream)
            for i in loaded {
                let s = i.repoTags.isEmpty ? "Loaded image ID: \(i.id)\n" : i.repoTags.map { "Loaded image: \($0)\n" }.joined()
                if !req.bool("quiet") { try await w.writeJSON(Line(stream: s), terminator: "\r\n") }
            }
        }
        t.get("images/get") { req, w in try await save(w, names: req.all("names")) }
        t.get("images/*name/get") { req, w in try await save(w, names: [req.param("name")]) }
        t.get("images/*name/json") { req, w in try await w.json(try await engine.inspectImage(req.param("name"))) }
        t.get("images/*name/history") { req, w in try await w.json(try await engine.imageHistory(req.param("name"))) }
        t.post("images/*name/push") { req, w in
            try await streamProgress(await engine.pushImage(req.param("name"), tag: req.string("tag"), registryAuth: req.headers.first(name: "X-Registry-Auth")), w)
        }
        t.post("images/*name/tag") { req, w in
            guard let repo = req.string("repo"), !repo.isEmpty else { throw APIError(status: 400, message: "repo is required") }
            try await engine.tagImage(req.param("name"), repo: repo, tag: req.string("tag")); try await w.empty(.created)
        }
        t.delete("images/*name") { req, w in
            try await w.json(try await engine.removeImage(req.param("name"), force: req.bool("force")))
        }
    }

    /// `docker save`: write the archive to a temp file, then stream it with a Content-Length.
    func save(_ w: ResponseWriter, names: [String]) async throws {
        guard !names.isEmpty else { throw APIError(status: 400, message: "names is required") }
        let spool = try Spool(dir: engine.paths.tmpDir)
        defer { spool.remove() }
        try spool.close()
        try await engine.saveImages(names, to: spool.url)
        let size = (try? FileManager.default.attributesOfItem(atPath: spool.url.path)[.size] as? Int64) ?? nil
        let handle = try FileHandle(forReadingFrom: spool.url)
        defer { try? handle.close() }
        if let size, size <= 1 << 20 {
            try await w.sendFile(spool.url, offset: 0, count: size, contentType: "application/x-tar")
            return
        }
        try await w.beginStream(contentType: "application/x-tar")
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try await w.write(chunk) }
    }
}
