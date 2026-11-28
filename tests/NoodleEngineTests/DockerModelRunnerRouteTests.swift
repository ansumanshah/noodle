import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NoodleCore
import Testing
@testable import NoodleAPI
@testable import NoodleEngine
@testable import NoodleImages

let fixtureModel = "hf.co/example/text-GGUF:Q4_K_M"

/// Wire fixtures follow upstream models/api.go, scheduling/api.go and oci/progress.go.
/// The channel is in memory. No VM, listener, weights download or native runtime is used.
@Suite("DockerModelRunnerRoute")
struct DockerModelRunnerRouteTests {
    @Test(arguments: ["", "/exp/vDD4.40"])
    func managementContract(prefix: String) async throws {
        let cli = ModelRunnerCLIStub()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-dmr-routes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        let harness = ModelRunnerRouteHarness(home: home, runner: runner)

        let list = try await harness.call(.GET, prefix + "/models")
        #expect(list.status == 200)
        let entries = try JSONDecoder().decode([DockerModelRunnerContract.Model].self, from: list.body)
        #expect(entries.count == 1)
        #expect(entries[0].tags == [fixtureModel])
        #expect(entries[0].config.format == "gguf")
        #expect(entries[0].created == 0)
        #expect(!String(decoding: list.body, as: UTF8.self).contains("fixture-private-key"))

        let inspect = try await harness.call(.GET, prefix + "/models/" + fixtureModel.replacingOccurrences(of: "/", with: "%2F"))
        #expect(inspect.status == 200)
        #expect(try JSONDecoder().decode(DockerModelRunnerContract.Model.self, from: inspect.body).id == entries[0].id)
        #expect(try await runner.inspect(String(entries[0].id.dropFirst(7).prefix(12))).id == entries[0].id)
        #expect(try await runner.inspect(fixtureModel.replacingOccurrences(of: "hf.co/", with: "huggingface.co/")).id == entries[0].id)
        #expect(try await harness.call(.GET, prefix + "/models/missing").status == 404)
        #expect(try await harness.call(.GET, prefix + "/models/" + fixtureModel + "?remote=true").status == 501)
        #expect(try await harness.call(.GET, prefix + "/models/..%2Fescape").status == 400)

        let status = try await harness.call(.GET, prefix + "/engines/status")
        #expect(try JSONDecoder().decode([String: String].self, from: status.body).isEmpty)
        let ps = try await harness.call(.GET, prefix + "/engines/ps")
        #expect(ps.status == 200)
        #expect(String(decoding: ps.body, as: UTF8.self) == "[]")
        let idleUnload = try await harness.call(.POST, prefix + "/engines/unload", body: #"{"all":true,"backend":"","models":[]}"#)
        #expect(try JSONDecoder().decode([String: Int].self, from: idleUnload.body)["unloaded_runners"] == 0)

        for base in ["/engines", "/engines/mlx"] {
            let models = try await harness.call(.GET, prefix + base + "/v1/models")
            let object = try #require(JSONSerialization.jsonObject(with: models.body) as? [String: Any])
            #expect(object["object"] as? String == "list")
            #expect((object["data"] as? [[String: Any]])?.first?["id"] as? String == fixtureModel)
            let model = try await harness.call(.GET, prefix + base + "/v1/models/" + fixtureModel)
            #expect(model.status == 200)
            #expect((try JSONSerialization.jsonObject(with: model.body) as? [String: Any])?["object"] as? String == "model")
            #expect(try await harness.call(.GET, prefix + base + "/v1/models/missing").status == 404)
            for path in ["chat/completions", "completions", "embeddings", "audio/speech"] {
                #expect(try await harness.call(.POST, prefix + base + "/v1/" + path, body: #"{"model":"missing"}"#).status == 404)
                #expect(try await harness.call(.POST, prefix + base + "/v1/" + path, body: "{").status == 400)
                #expect(try await harness.call(.POST, prefix + base + "/v1/" + path, body: "{}").status == 400)
            }
            // Multipart names its model in a form field, so the JSON guard must never see it: the route does not exist.
            #expect(try await harness.call(.POST, prefix + base + "/v1/audio/transcriptions", body: "--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--b--\r\n").status == 404)
        }

        let pull = try await harness.call(.POST, prefix + "/models/create", body: #"{"from":"hf.co/example/text-GGUF:q4_k_m"}"#)
        #expect(pull.status == 200)
        let progress = try #require(JSONSerialization.jsonObject(with: pull.body) as? [String: Any])
        #expect(progress["type"] as? String == "success")
        #expect(progress["mode"] as? String == "pull")
        #expect(progress["layer"] is [String: Any])
        #expect(await cli.wasCalled(["pull", fixtureModel]))
        #expect(try await harness.call(.POST, prefix + "/models/create", body: #"{"from":"-flag"}"#).status == 400)
        // A signed-in plugin sends its Docker Hub token; the pull still runs anonymously.
        #expect(try await harness.call(.POST, prefix + "/models/create", body: #"{"from":"\#(fixtureModel)","bearer-token":"private"}"#).status == 200)
        #expect(try await harness.call(.POST, prefix + "/models/create", body: "{}").status == 400)

        let configure = #"{"model":"hf.co/example/text-GGUF:Q4_K_M","mode":"completion","runtime-flags":[]}"#
        #expect(try await harness.call(.POST, prefix + "/engines/_configure", body: configure).status == 202)
        #expect(try await harness.call(.POST, prefix + "/engines/mlx/_configure", body: configure).status == 202)
        let activeStatus = try await harness.call(.GET, prefix + "/engines/status")
        #expect(try JSONDecoder().decode([String: String].self, from: activeStatus.body) == ["mlx": "Running"])
        let activePS = try await harness.call(.GET, prefix + "/engines/ps")
        let active = try #require((JSONSerialization.jsonObject(with: activePS.body) as? [[String: Any]])?.first)
        #expect(active["backend_name"] as? String == "mlx")
        #expect(active["model_name"] as? String == fixtureModel)
        #expect(active["mode"] as? String == "completion")
        #expect(try await harness.call(.POST, prefix + "/engines/missing/_configure", body: configure).status == 404)
        #expect(try await harness.call(.POST, prefix + "/engines/_configure", body: #"{"model":"hf.co/example/text-GGUF:Q4_K_M","context-size":8192}"#).status == 501)
        #expect(try await harness.call(.POST, prefix + "/engines/_configure", body: configure.replacingOccurrences(of: "[]", with: #"["--shell"]"#)).status == 501)
        #expect(try await harness.call(.POST, prefix + "/engines/_configure", body: #"{"model":"fixture","unknown":true}"#).status == 501)
        #expect(try await harness.call(.POST, prefix + "/engines/_configure", body: "{}").status == 400)
        #expect(try await harness.call(.POST, prefix + "/engines/unload", body: "{}").status == 200)

        let log = try await harness.call(.GET, prefix + "/logs")
        #expect(log.status == 200)
        #expect(String(decoding: log.body, as: UTF8.self) == "engine log\n")
        #expect(try await harness.call(.GET, prefix + "/logs?no-engines=true").body.isEmpty)
        #expect(try await harness.call(.GET, prefix + "/logs?follow=true").status == 501)
        #expect(try await harness.call(.DELETE, prefix + "/models/" + fixtureModel).status == 409)
        let unloaded = try await harness.call(.POST, prefix + "/engines/unload", body: #"{"all":true}"#)
        #expect(try JSONDecoder().decode([String: Int].self, from: unloaded.body)["unloaded_runners"] == 1)
        let removed = try await harness.call(.DELETE, prefix + "/models/" + fixtureModel)
        #expect(removed.status == 200)
        let actions = try JSONDecoder().decode([[String: String]].self, from: removed.body)
        #expect(actions.first == ["Untagged": fixtureModel])
        #expect(actions.last == ["Deleted": entries[0].id])
        #expect(try await harness.call(.DELETE, prefix + "/models/" + fixtureModel).status == 404)
    }

    @Test func inferenceLeaseKeepsTheKeyPrivateAndBlocksLifecycleChanges() async throws {
        let cli = ModelRunnerCLIStub()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-dmr-lease-" + UUID().uuidString)
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        let input = Data(#"{"model":"hf.co/example/text-GGUF:q4_k_m","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
        let inference = try await runner.beginInference(input, backend: "mlx")
        #expect(inference.endpoint.apiKey == "fixture-private-key")
        let translated = try #require(JSONSerialization.jsonObject(with: inference.body) as? [String: Any])
        #expect(translated["model"] as? String == String(fixtureModel.dropFirst(6)))
        #expect(translated["stream"] as? Bool == true)
        #expect(!String(decoding: inference.body, as: UTF8.self).contains("fixture-private-key"))
        do {
            _ = try await runner.unload(all: true, backend: "", models: [])
            Issue.record("Unloaded during inference")
        } catch let error as DockerModelRunnerError { #expect(error.status == 409) }
        await runner.endInference()
        #expect(try await runner.unload(all: false, backend: "mlx", models: [fixtureModel]) == 1)
    }

    @Test(arguments: ["https://127.0.0.1:11345/v1", "http://192.168.64.1:11345/v1", "http://127.0.0.1:11345/admin",
                      "http://127.0.0.1:11345/v1?key=x", "http://user@127.0.0.1:11345/v1", "http://127.0.0.1:11345/v1#fragment"])
    func rejectsAnEndpointOutsideThePrivateRunnerContract(url: String) async throws {
        let cli = ModelRunnerCLIStub(endpoint: URL(string: url)!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        do {
            _ = try await runner.beginInference(Data(#"{"model":"hf.co/example/text-GGUF:Q4_K_M"}"#.utf8), backend: "")
            Issue.record("Accepted unsafe endpoint")
        } catch let error as DockerModelRunnerError { #expect(error.status == 409) }
    }

    @Test func acceptsOnlyRepresentableDockerOCIArtifacts() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let config = Descriptor(mediaType: "application/vnd.docker.ai.model.config.v0.1+json", digest: digest, size: 100)
        let weights = Descriptor(mediaType: "application/vnd.docker.ai.gguf.v3", digest: digest, size: 24)
        let license = Descriptor(mediaType: "application/vnd.docker.ai.license", digest: digest, size: 20)
        let valid = Manifest(schemaVersion: 2, config: config, layers: [weights, license])
        #expect(try DockerModelRunner.ggufLayer(valid).weights == weights)
        for layers in [[weights, weights], [license], [weights, Descriptor(mediaType: "application/vnd.docker.ai.mmproj", digest: digest, size: 1)],
                       [Descriptor(mediaType: weights.mediaType, digest: "sha256:bad", size: 24)]] {
            #expect(throws: DockerModelRunnerError.self) { try DockerModelRunner.ggufLayer(Manifest(schemaVersion: 2, config: config, layers: layers)) }
        }
        #expect(try DockerModelRunner.hubReference("ai/example").familiar == "ai/example:latest")
        #expect(try DockerModelRunner.hubReference("example:tag").familiar == "ai/example:tag")
        #expect(throws: DockerModelRunnerError.self) { try DockerModelRunner.hubReference("ghcr.io/ai/example") }
        #expect(throws: DockerModelRunnerError.self) { try DockerModelRunner.hubReference("docker.io/user/example") }
    }

    @Test func sharedOCITagsPreserveWeightsAndForceDeletionStopsTheRunner() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-dmr-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "sha256:" + String(repeating: "a", count: 64)
        let model = DockerModelRunnerContract.Model(id: id, tags: ["ai/example:latest", "ai/alias:latest"], created: 0,
                                                    config: .init(format: "gguf", size: "24", context_size: 4096))
        let receipt = DockerModelRunner.Receipt(localID: "dmr-fixture", model: model)
        try JSONEncoder().encode([receipt]).write(to: directory.appendingPathComponent("docker-models.json"))
        let cli = ModelRunnerCLIStub(id: "dmr-fixture")
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        let harness = ModelRunnerRouteHarness(home: home, runner: runner)
        #expect(try await harness.call(.DELETE, "/models/" + id).status == 409)
        let untag = try await harness.call(.DELETE, "/models/ai/example")
        #expect(untag.status == 200)
        #expect(try JSONDecoder().decode([[String: String]].self, from: untag.body) == [["Untagged": "ai/example:latest"]])
        #expect(await !cli.wasCalled(["rm", "dmr-fixture"]))
        #expect(try await runner.inspect("ai/alias").tags == ["ai/alias:latest"])
        try await runner.configure("ai/alias")
        #expect(try await harness.call(.DELETE, "/models/" + id + "?force=true").status == 200)
        #expect(await cli.wasCalled(["stop"]))
        #expect(await cli.wasCalled(["rm", "dmr-fixture"]))
        #expect(try await runner.list().isEmpty)
    }

    @Test func oneEngineReportsAndUnloadsMultipleModels() async throws {
        let cli = ModelRunnerCLIStub(additional: ["second"])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        async let first: Void = runner.configure(fixtureModel)
        async let second: Void = runner.configure("second")
        _ = try await (first, second)
        #expect(try await runner.running().count == 2)
        #expect(try await runner.unload(all: false, backend: "mlx", models: [fixtureModel]) == 1)
        #expect(try await runner.running().map(\.model_name) == ["second"])
        #expect(try await runner.unload(all: true, backend: "", models: []) == 1)
        #expect(try await runner.running().isEmpty)
    }
}

actor ModelRunnerCLIStub {
    private var installed = true
    private var served: String?
    private var calls: [[String]] = []
    private let endpoint: URL
    private let id: String
    private let additional: [String]
    private var activeModels: Set<String> = []
    init(endpoint: URL = URL(string: "http://127.0.0.1:11345/v1")!, id: String = fixtureModel, additional: [String] = []) {
        self.endpoint = endpoint; self.id = id; self.additional = additional
    }
    func wasCalled(_ arguments: [String]) -> Bool { calls.contains(arguments) }
    func snapshot() -> [DockerModelRunner.Record] { activeModels.sorted().map { .init(id: $0.hasPrefix("hf.co/") ? String($0.dropFirst(6)) : $0) } }
    func run(_ arguments: [String]) throws -> Data {
        calls.append(arguments)
        switch arguments {
        case ["list", "--json"]:
            return try JSONEncoder().encode(installed ? ([id] + additional).map { LocalModel(id: $0, name: "Fixture", bytes: 24, installed: true, downloadable: true) } : [])
        case ["status", "--json"]:
            return try JSONEncoder().encode(LocalModelStatus(phase: served == nil ? .stopped : .ready, model: served, backend: .llamaCPP))
        case ["endpoint", "--json"]:
            return try JSONEncoder().encode(LocalModelEndpoint(model: (served ?? id).hasPrefix("hf.co/") ? String((served ?? id).dropFirst(6)) : (served ?? id), baseURL: endpoint, apiKey: "fixture-private-key", backend: .llamaCPP))
        case ["logs"]: return Data("engine log\n".utf8)
        case ["stop"]:
            if let served { activeModels.remove(served) }
            served = activeModels.sorted().first
            return Data()
        case let args where args.count == 2 && args[0] == "serve": served = args[1]; activeModels.insert(args[1]); return Data()
        case let args where args.count == 2 && args[0] == "rm": installed = false; return Data()
        case let args where args.count == 2 && args[0] == "pull": installed = true; return Data()
        default: throw DockerModelRunnerError(500, "Unexpected fixture command")
        }
    }
}

struct ModelRunnerRouteHarness {
    let home: URL
    let runner: DockerModelRunner
    var sessionConfiguration: URLSessionConfiguration? = nil
    struct Reply { var status: Int; var body: Data; var contentType: String? }
    func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws -> Reply {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let inbox = ByteInbox(channel: channel)
        inbox.feed(channel.allocator.buffer(string: body))
        inbox.finish()
        let parts = URLParts.split(uri: uri)
        let request = Request(method: method, segments: URLParts.segments(parts.path), query: URLParts.parseQuery(parts.query),
                              headers: [:], apiVersion: APIInfo.apiVersion, body: inbox)
        let pipeline = PipelineParts(decoder: ByteToMessageHandler(HTTPRequestDecoder()), encoder: HTTPResponseEncoder())
        let writer = ResponseWriter(channel: channel, parts: pipeline, keepAlive: false, isHead: false,
                                    upgradeRequested: nil)
        var table = RouteTable()
        Handlers(engine: Engine(paths: NoodlePaths(root: home))).modelRunnerRoutes(&table, runner: runner, sessionConfiguration: sessionConfiguration)
        await Router(table: table).serve(request, writer)
        var reply = Reply(status: 0, body: Data())
        while let part = try await channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head): reply.status = Int(head.status.code); reply.contentType = head.headers.first(name: "Content-Type")
            case .body(.byteBuffer(let bytes)): reply.body.append(contentsOf: bytes.readableBytesView)
            default: break
            }
        }
        _ = try await channel.finish(acceptAlreadyClosed: true)
        return reply
    }
}
