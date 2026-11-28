import Foundation
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func modelRunnerRoutes(_ table: inout RouteTable, runner: DockerModelRunner? = nil,
                           sessionConfiguration: URLSessionConfiguration? = nil) {
        let runner = runner ?? DockerModelRunner(home: engine.paths.root)
        // Desktop's socket prefix and the runner's native paths share one implementation.
        for prefix in ["", "exp/vDD4.40/"] {
            func route(_ method: HTTPMethod, _ path: String, _ handler: @escaping Handler) {
                table.add(method, prefix + path) { request, writer in
                    do { try await handler(request, writer) }
                    catch let error as DockerModelRunnerError {
                        if writer.started { throw error }
                        try await writer.text(error.description + "\n", status: .init(statusCode: error.status))
                    }
                }
            }
            route(.GET, "models") { _, writer in try await writer.json(try await runner.list()) }
            route(.POST, "models/create") { request, writer in
                // The plugin sends the signed-in Docker Hub token as "bearer-token"; pulls are anonymous, so it is ignored.
                struct Pull: Decodable { var from: String }
                guard let pull = try await request.json(Pull.self) else { throw DockerModelRunnerError(400, "from is required") }
                // HTTP status carries failures, including failed installs. Success is a DMR progress line, not Docker image JSON.
                try await runner.pull(pull.from)
                try await writer.beginStream(contentType: "application/json")
                try await writer.writeJSON(DockerModelRunnerContract.Progress(type: "success", message: "Model pulled"))
            }
            route(.GET, "models/*name") { request, writer in
                guard !request.bool("remote") else { throw DockerModelRunnerError(501, "Remote model inspection is not supported") }
                try await writer.json(try await runner.inspect(request.param("name")))
            }
            route(.DELETE, "models/*name") { request, writer in
                try await writer.json(try await runner.remove(request.param("name"), force: request.bool("force")))
            }
            route(.GET, "engines/status") { _, writer in try await writer.json(try await runner.backendStatus()) }
            route(.GET, "engines/ps") { _, writer in try await writer.json(try await runner.running()) }
            route(.POST, "engines/unload") { request, writer in
                struct Unload: Decodable { var all: Bool?; var backend: String?; var models: [String]? }
                guard let unload = try await request.json(Unload.self) else { throw DockerModelRunnerError(400, "invalid request") }
                let count = try await runner.unload(all: unload.all ?? false, backend: unload.backend ?? "", models: unload.models ?? [])
                try await writer.json(["unloaded_runners": count])
            }
            for engine in ["engines", "engines/{backend}"] {
                route(.POST, engine + "/_configure") { request, writer in
                    let body = try await request.body.readAll(limit: 1 << 20)
                    guard let config = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          let model = config["model"] as? String else { throw DockerModelRunnerError(400, "model is required") }
                    let supported: Set<String> = ["model", "context-size", "mode", "runtime-flags", "raw-runtime-flags"]
                    guard Set(config.keys).isSubset(of: supported),
                          config["mode"] == nil || config["mode"] as? String == "completion",
                          config["runtime-flags"] == nil || (config["runtime-flags"] as? [String])?.isEmpty == true,
                          config["raw-runtime-flags"] == nil || config["raw-runtime-flags"] as? String == "" else {
                        throw DockerModelRunnerError(501, "Runtime flags, alternate modes and nondefault runner settings are not supported")
                    }
                    if let size = config["context-size"], !(size is Int) { throw DockerModelRunnerError(400, "invalid context-size") }
                    try await runner.configure(model, backend: request.param("backend"), contextSize: config["context-size"] as? Int)
                    try await writer.empty(.accepted)
                }
                route(.GET, engine + "/v1/models") { _, writer in try await writer.json(try await runner.openAIModels()) }
                route(.GET, engine + "/v1/models/*name") { request, writer in
                    let models = try await runner.openAIModels(request.param("name"))
                    try await writer.json(models.data[0])
                }
                // audio/transcriptions is multipart and names its model in a form field, so it is not forwarded here.
                for path in ["chat/completions", "completions", "embeddings", "audio/speech"] {
                    route(.POST, engine + "/v1/" + path) { request, writer in
                        let data = try await request.body.readAll(limit: 10 << 20)
                        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                            throw DockerModelRunnerError(400, "invalid request")
                        }
                        let inference = try await runner.beginInference(data, backend: request.param("backend"))
                        do {
                            try await Self.forwardModelInference(inference, path: path, writer: writer, configuration: sessionConfiguration)
                            await runner.endInference()
                        } catch {
                            await runner.endInference()
                            throw error
                        }
                    }
                }
            }
            route(.GET, "logs") { request, writer in
                guard !request.bool("follow") else { throw DockerModelRunnerError(501, "Following model logs is not supported") }
                let logs = request.bool("no-engines") ? Data() : try await runner.logs()
                try await writer.text(String(decoding: logs, as: UTF8.self))
            }
        }
    }

    private static func forwardModelInference(_ inference: DockerModelRunner.Inference, path: String, writer: ResponseWriter,
                                              configuration: URLSessionConfiguration?) async throws {
        let url = inference.endpoint.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.httpBody = inference.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + inference.endpoint.apiKey, forHTTPHeaderField: "Authorization")
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ModelRunnerRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DockerModelRunnerError(502, "Invalid model response") }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        try await writer.beginStream(.init(statusCode: response.statusCode), contentType: contentType)
        var chunk = Data()
        let sse = contentType.hasPrefix("text/event-stream")
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16 << 10 || sse && byte == 10 {
                try await writer.write(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await writer.write(chunk) }
    }
}

private final class ModelRunnerRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
