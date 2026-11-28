import Foundation
import NIOHTTP1
import NoodleCore
import NoodleEngine

/// A URL capability is needed because upstream Compose injects a URL and model, but no key header.
struct ModelRunnerAccess: Codable, Sendable {
    let key: String
    let port: Int
    var prefix: String { "/model-runner/" + key }
    var connection: ModelRunnerConnection {
        .init(host: "http://host.docker.internal:\(port)" + prefix, proxy: "http://127.0.0.1:\(port)")
    }

    func target(_ uri: String, method: HTTPMethod, loopback: Bool) throws -> String {
        let path: String
        let query: String
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            guard let url = URLComponents(string: uri), url.scheme == "http", url.host == "host.docker.internal",
                  url.port == port, url.user == nil, url.password == nil, url.fragment == nil else {
                throw DockerModelRunnerError(400, "Invalid Model Runner proxy target")
            }
            path = url.percentEncodedPath
            query = url.percentEncodedQuery.map { "?" + $0 } ?? ""
        } else {
            let parts = URLParts.split(uri: uri)
            path = parts.path
            query = parts.query.isEmpty ? "" : "?" + parts.query
        }
        guard path.hasPrefix(prefix + "/") else { throw DockerModelRunnerError(401, "Model Runner key required") }
        var target = String(path.dropFirst(prefix.count))
        if target.hasPrefix("/v1/") { target = "/engines" + target }
        if !loopback {
            let parts = URLParts.segments(target)
            let metadata = (method == .GET || method == .HEAD) &&
                (target == "/models" || target.hasPrefix("/engines/v1/models") || target.hasPrefix("/engines/mlx/v1/models"))
            let inference = method == .POST &&
                ["/engines/v1/chat/completions", "/engines/v1/completions", "/engines/v1/embeddings",
                 "/engines/v1/audio/speech", "/engines/mlx/v1/chat/completions", "/engines/mlx/v1/completions",
                 "/engines/mlx/v1/embeddings", "/engines/mlx/v1/audio/speech"].contains(target)
            guard metadata || inference, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") }) else {
                throw DockerModelRunnerError(403, "Model management requires the local Docker socket")
            }
        }
        return target + query
    }
}
