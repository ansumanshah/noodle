import Foundation
import NIOCore
import NoodleEngine

/// Private endpoints for the native build helper. It holds the per-builder capability token and uses them to ask the
/// Mac to resolve a base image, then to read the resolved blobs. Registry credentials stay in this process.
extension Handlers {
    func buildBaseRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        @Sendable func token(_ req: Request) throws -> String {
            guard let token = req.headers.first(name: "X-Noodle-Build-Token"), token.count == 36 else {
                throw APIError(status: 403, message: "missing build capability")
            }
            return token
        }
        t.post("noodle/buildkit/base") { req, w in
            struct Input: Decodable { let Ref: String; let Pull: Bool? }
            let token = try token(req)
            let input = try await req.decode(Input.self, limit: 64 << 10, invalid: "invalid base request")
            let digest = try await engine.nativeBaseDigest(token: token, reference: input.Ref, pull: input.Pull ?? false)
            try await w.json(["Digest": digest ?? ""])
        }
        t.get("noodle/buildkit/blob/{digest}") { req, w in
            let (url, size) = try await engine.nativeBaseBlob(token: try token(req), digest: req.param("digest"))
            let offset = Int64(req.string("offset") ?? "0") ?? -1
            guard offset >= 0, offset <= size else { throw APIError(status: 416, message: "invalid blob range") }
            let length = Int64(req.string("length") ?? "") ?? size - offset
            guard length >= 0, length <= 16 << 20 else {
                throw APIError(status: 416, message: "invalid blob range")
            }
            let count = min(length, size - offset)
            try await w.sendFile(url, offset: offset, count: count, contentType: "application/octet-stream",
                                 headers: [("X-Noodle-Blob-Size", String(size))])
        }
    }
}
