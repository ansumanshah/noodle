import Foundation
import NoodleCore
import NoodleImages

/// Docker's wire shapes, from model-runner/pkg/inference/{models,scheduling}/api.go.
public enum DockerModelRunnerContract {
    public struct Config: Codable, Sendable {
        public var format: String
        public var size: String
        public var context_size: Int?
    }
    public struct Model: Codable, Sendable {
        public var id: String
        public var tags: [String]
        public var created: Int64
        public var config: Config
    }
    public struct Running: Encodable, Sendable {
        public var backend_name: String
        public var model_name: String
        public var mode = "completion"
        public var loading: Bool
        public var in_use: Bool
    }
    public struct OpenAIModel: Encodable, Sendable {
        public var id: String
        public var object = "model"
        public var created: Int64
        public var owned_by = "noodle"
    }
    public struct OpenAIList: Encodable, Sendable {
        public var object = "list"
        public var data: [OpenAIModel]
    }
    public struct Progress: Encodable, Sendable {
        public struct Layer: Encodable, Sendable {
            public var size: UInt64 = 0
            public var current: UInt64 = 0
        }
        public var type: String
        public var message: String
        public var total: UInt64 = 0
        public var layer = Layer()
        public var mode = "pull"
        public init(type: String, message: String) { self.type = type; self.message = message }
    }
}

/// A socket-scoped adapter. It never listens on TCP or changes host-loopback relay policy.
public actor DockerModelRunner {
    public struct Record: Decodable, Sendable {
        public let id: String
        public let loaded: Bool?
        public init(id: String, loaded: Bool? = true) { self.id = id; self.loaded = loaded }
    }
    public typealias Snapshot = @Sendable () async throws -> [Record]
    typealias Model = DockerModelRunnerContract.Model
    let home: URL
    let command: DockerModelCommand.Run
    private let snapshot: Snapshot?
    private var changing = false
    private var changes: [CheckedContinuation<Void, Never>] = []
    private var requests = 0

    public init(home: URL, command: DockerModelCommand.Run? = nil, snapshot: Snapshot? = nil) {
        self.home = home
        let cli = DockerModelCommand(home: home)
        self.command = command ?? { try await cli.run($0) }
        self.snapshot = snapshot
    }

    public func list() async throws -> [DockerModelRunnerContract.Model] {
        let native = try await installed()
        let receipts = try await receipts()
        let mapped = Set(receipts.map(\.localID))
        var result = receipts.filter { receipt in native.contains { $0.id == receipt.localID } }.map(\.model)
        result += native.filter { !mapped.contains($0.id) }.map {
            Model(id: Digest.sha256(Data($0.id.utf8)), tags: [$0.id], created: 0,
                  config: .init(format: $0.backend == .llamaCPP ? "gguf" : "safetensors", size: String($0.bytes), context_size: nil))
        }
        return result.sorted { ($0.tags.first ?? $0.id) < ($1.tags.first ?? $1.id) }
    }

    public func inspect(_ reference: String) async throws -> DockerModelRunnerContract.Model {
        try await resolve(reference).model
    }

    public func openAIModels(_ reference: String? = nil) async throws -> DockerModelRunnerContract.OpenAIList {
        let models: [Model]
        if let reference { models = [try await inspect(reference)] }
        else { models = try await list() }
        return .init(data: models.map { .init(id: $0.tags.first ?? $0.id, created: $0.created) })
    }

    public func pull(_ reference: String) async throws {
        try await beginChange()
        defer { endChange() }
        try Self.validate(reference)
        let reference = Self.huggingFaceSpelling(reference)
        if reference.hasPrefix("hf.co/") {
            let id: String
            do { id = try LocalModelHuggingFace.Reference(reference).id }
            catch { throw DockerModelRunnerError(400, "Invalid Hugging Face model reference") }
            _ = try await command(["pull", id])
        } else if !reference.contains("/") && !reference.contains(":") {
            guard reference.range(of: #"^[a-z0-9][a-z0-9.-]{0,62}$"#, options: .regularExpression) != nil else {
                throw DockerModelRunnerError(400, "Invalid local model ID")
            }
            let catalog = try JSONDecoder().decode([LocalModel].self, from: await command(["catalog", "--json"]))
            if catalog.contains(where: { $0.id == reference }) { _ = try await command(["pull", reference]) }
            else { try await pullOCI(reference) }
        } else { try await pullOCI(reference) }
    }

    public func remove(_ reference: String, force: Bool) async throws -> [[String: String]] {
        try await beginChange()
        defer { endChange() }
        let resolved = try await resolve(reference)
        if resolved.model.tags.count > 1 {
            let canonical = (try? Self.hubReference(reference).familiar) ?? reference
            if let tag = resolved.model.tags.first(where: { $0 == reference || $0 == canonical }) {
                try await removeTag(tag, localID: resolved.localID)
                return [["Untagged": tag]]
            }
            guard force else { throw DockerModelRunnerError(409, "Model has multiple tags; use force to remove by ID") }
        }
        let current = try await status()
        let loaded = current.phase == .stopped ? [] : try await records()
        if loaded.contains(where: { $0.id == Self.engineModelID(resolved.localID) && $0.loaded != false }) {
            guard force else { throw DockerModelRunnerError(409, "Model is running; unload it before removing it") }
            try await ensureRunning(resolved.localID)
            _ = try await command(["stop"])
        }
        _ = try await command(["rm", resolved.localID])
        try await removeReceipt(localID: resolved.localID)
        return resolved.model.tags.map { ["Untagged": $0] } + [["Deleted": resolved.model.id]]
    }

    public func backendStatus() async throws -> [String: String] {
        let current = try await status()
        // Only report a backend we observed. CLI startup installs its runtime lazily.
        guard current.phase != .stopped else { return [:] }
        let backend = "mlx"
        return [backend: current.phase == .ready ? "Running" : "Installing: starting model"]
    }

    public func running() async throws -> [DockerModelRunnerContract.Running] {
        let current = try await status()
        guard current.phase != .stopped else { return [] }
        let native = try await installed()
        let saved = try await receipts()
        return try await records().filter { $0.loaded != false }.map { record in
            let local = native.first { Self.engineModelID($0.id) == record.id }?.id ?? record.id
            let name = saved.first { $0.localID == local }?.model.tags.first ?? local
            return .init(backend_name: "mlx", model_name: name, loading: current.phase == .starting, in_use: requests > 0)
        }
    }

    public func unload(all: Bool, backend: String, models: [String]) async throws -> Int {
        try await beginChange()
        defer { endChange() }
        let current = try await status()
        guard current.phase != .stopped else { return 0 }
        let activeBackend = "mlx"
        guard backend.isEmpty || backend == activeBackend else { return 0 }
        let loaded = try await records().filter { $0.loaded != false }
        let installed = try await installed()
        var selected: [String] = []
        for record in loaded {
            let local = installed.first { Self.engineModelID($0.id) == record.id }?.id ?? record.id
            if all { selected.append(local); continue }
            for model in models {
                do { if try await resolve(model).localID == local { selected.append(local); break } }
                catch let error as DockerModelRunnerError where error.status == 404 { continue }
            }
        }
        for model in selected {
            try await ensureRunning(model)
            _ = try await command(["stop"])
        }
        return selected.count
    }

    public func configure(_ reference: String, backend: String = "", contextSize: Int? = nil) async throws {
        try await beginChange()
        defer { endChange() }
        guard contextSize == nil else {
            throw DockerModelRunnerError(501, "Context-size overrides are not supported by the model CLI")
        }
        let resolved = try await resolve(reference)
        try Self.checkBackend(backend)
        try await ensureRunning(resolved.localID)
    }

    public struct Inference: Sendable {
        public let endpoint: LocalModelEndpoint
        public let body: Data
    }

    public func beginInference(_ body: Data, backend: String) async throws -> Inference {
        guard !changing else { throw DockerModelRunnerError(409, "Model lifecycle operation in progress") }
        guard var json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reference = json["model"] as? String else { throw DockerModelRunnerError(400, "model is required") }
        changing = true
        defer { endChange() }
        let resolved = try await resolve(reference)
        try Self.checkBackend(backend)
        try await ensureRunning(resolved.localID)
        let endpoint = try JSONDecoder().decode(LocalModelEndpoint.self, from: await command(["endpoint", "--json"]))
        guard endpoint.model == resolved.localID || endpoint.model == Self.engineModelID(resolved.localID), endpoint.baseURL.scheme == "http",
              endpoint.baseURL.host == "127.0.0.1" || endpoint.baseURL.host == "::1",
              endpoint.baseURL.path == "/v1", endpoint.baseURL.query == nil, endpoint.baseURL.user == nil,
              endpoint.baseURL.password == nil, endpoint.baseURL.fragment == nil else {
            throw DockerModelRunnerError(409, "Model endpoint changed or is not a private loopback endpoint")
        }
        json["model"] = endpoint.model
        let translated = try JSONSerialization.data(withJSONObject: json)
        requests += 1
        return .init(endpoint: endpoint, body: translated)
    }

    public func endInference() { requests -= 1 }

    public func logs() async throws -> Data { try await command(["logs"]) }

    private func beginChange() async throws {
        while changing {
            await withCheckedContinuation { changes.append($0) }
            if Task.isCancelled { resumeChange(); throw CancellationError() }
        }
        guard requests == 0 else { resumeChange(); throw DockerModelRunnerError(409, "Model is busy") }
        changing = true
    }

    private func endChange() { changing = false; resumeChange() }
    private func resumeChange() {
        if !changing, !changes.isEmpty { changes.removeFirst().resume() }
    }

    private func installed() async throws -> [LocalModel] {
        try JSONDecoder().decode([LocalModel].self, from: await command(["list", "--json"]))
    }

    private func status() async throws -> LocalModelStatus {
        try JSONDecoder().decode(LocalModelStatus.self, from: await command(["status", "--json"]))
    }

    private func records() async throws -> [Record] {
        if let snapshot { return try await snapshot() }
        let endpoint = try JSONDecoder().decode(LocalModelEndpoint.self, from: await command(["endpoint", "--json"]))
        guard endpoint.baseURL.scheme == "http", ["127.0.0.1", "::1"].contains(endpoint.baseURL.host ?? ""),
              endpoint.baseURL.path == "/v1", endpoint.baseURL.user == nil, endpoint.baseURL.password == nil,
              endpoint.baseURL.query == nil, endpoint.baseURL.fragment == nil else {
            throw DockerModelRunnerError(409, "Model endpoint is not private loopback")
        }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"), timeoutInterval: 10)
        request.setValue("Bearer " + endpoint.apiKey, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ModelMetadataRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1 << 20 else {
            throw DockerModelRunnerError(502, "Cannot read model load state")
        }
        struct Models: Decodable { let data: [Record] }
        let records = try JSONDecoder().decode(Models.self, from: data).data
        if records.contains(where: { $0.loaded != nil }) { return records.filter { $0.loaded == true } }
        let current = try await status().model.map(Self.engineModelID)
        return records.filter { $0.id == current }
    }

    private func ensureRunning(_ id: String) async throws {
        let current = try await status()
        // mlx-serve keeps one process and port, and loads another model through the CLI.
        if current.phase != .ready || current.model != id { _ = try await command(["serve", id]) }
    }

    private func resolve(_ reference: String) async throws -> (model: Model, localID: String) {
        try Self.validate(reference)
        let native = try await installed()
        let receipts = try await receipts()
        let models = try await list()
        let canonical = (try? LocalModelHuggingFace.Reference(Self.huggingFaceSpelling(reference)).id) ?? (try? Self.hubReference(reference).familiar) ?? reference
        let model = models.first { $0.id == reference || $0.tags.contains(reference) || $0.tags.contains(canonical) }
            ?? models.first { model in
                let hex = String(model.id.dropFirst("sha256:".count))
                return model.id.hasPrefix("sha256:") && (reference == hex || reference.count == 12 && hex.hasPrefix(reference))
            }
        guard let model else {
            throw DockerModelRunnerError(404, "Model not found: \(reference)")
        }
        guard let local = receipts.first(where: { $0.model.id == model.id })?.localID ?? model.tags.first else {
            throw DockerModelRunnerError(422, "Installed model is missing its local identity")
        }
        guard native.contains(where: { $0.id == local }) else { throw DockerModelRunnerError(404, "Model not found") }
        return (model, local)
    }

    static func validate(_ reference: String) throws {
        guard !reference.isEmpty, reference.utf8.count <= 512, !reference.hasPrefix("-"),
              !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }),
              !reference.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw DockerModelRunnerError(400, "Invalid model reference")
        }
    }

    private static func huggingFaceSpelling(_ reference: String) -> String {
        reference.hasPrefix("huggingface.co/") ? "hf.co/" + reference.dropFirst("huggingface.co/".count) : reference
    }

    private static func engineModelID(_ reference: String) -> String {
        reference.hasPrefix("hf.co/") ? String(reference.dropFirst(6)) : reference
    }

    private static func checkBackend(_ backend: String) throws {
        guard backend.isEmpty || backend == "mlx" else { throw DockerModelRunnerError(404, "Backend not found for this model") }
    }
}

private final class ModelMetadataRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
