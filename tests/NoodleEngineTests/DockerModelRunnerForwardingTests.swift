import Foundation
import NIOHTTP1
import Synchronization
import Testing
@testable import NoodleEngine

@Suite("DockerModelRunnerForwarding", .serialized)
struct DockerModelRunnerForwardingTests {
    @Test(arguments: ["", "/exp/vDD4.40"])
    func forwardsAuthenticatedOpenAIAndSSE(prefix: String) async throws {
        let cli = ModelRunnerCLIStub()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-dmr-forward-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = DockerModelRunner(home: home, command: { try await cli.run($0) }, snapshot: { await cli.snapshot() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelRunnerHTTPFixture.self]
        let harness = ModelRunnerRouteHarness(home: home, runner: runner, sessionConfiguration: configuration)
        for backend in ["", "/mlx"] {
            for path in ["chat/completions", "completions", "embeddings"] {
                ModelRunnerHTTPFixture.requests.withLock { $0.removeAll() }
                let response = try await harness.call(.POST, prefix + "/engines" + backend + "/v1/" + path,
                    body: #"{"model":"hf.co/example/text-GGUF:q4_k_m","messages":[{"role":"user","content":"hi"}],"stream":true}"#)
                let captured = ModelRunnerHTTPFixture.requests.withLock { $0 }
                let request = try #require(captured.first)
                #expect(captured.count == 1)
                #expect(request.url?.absoluteString == "http://127.0.0.1:11345/v1/" + path)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-private-key")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                let translated = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(translated["model"] as? String == String(fixtureModel.dropFirst(6)))
                #expect(translated["stream"] as? Bool == true)
                #expect(!String(decoding: response.body, as: UTF8.self).contains("fixture-private-key"))
                if path == "chat/completions" {
                    #expect(response.status == 200)
                    #expect(response.contentType == "text/event-stream")
                    #expect(response.body == ModelRunnerHTTPFixture.sse)
                } else if path == "embeddings" {
                    #expect(response.status == 422)
                    #expect(response.contentType == "application/json")
                    #expect(response.body == ModelRunnerHTTPFixture.unsupportedEmbedding)
                } else {
                    #expect(response.status == 200)
                    #expect(response.body == ModelRunnerHTTPFixture.completion)
                }
            }
        }
        // Every success and upstream HTTP error released its inference lease.
        #expect(try await runner.unload(all: true, backend: "", models: []) == 1)
    }
}

private final class ModelRunnerHTTPFixture: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    // OpenAI shapes consumed by upstream desktop/desktop.go's Chat/Completions methods.
    static let sse = Data("data: {\"id\":\"chatcmpl-fixture\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n".utf8)
    static let completion = Data(#"{"id":"cmpl-fixture","choices":[{"text":"hi"}]}"#.utf8)
    static let unsupportedEmbedding = Data(#"{"error":{"message":"Model does not support embeddings","type":"invalid_request_error"}}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.requests.withLock { $0.append(captured) }
        let path = request.url!.path
        let embedding = path.hasSuffix("/embeddings")
        let streaming = path.hasSuffix("/chat/completions")
        let response = HTTPURLResponse(url: request.url!, statusCode: embedding ? 422 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = streaming ? Self.sse : embedding ? Self.unsupportedEmbedding : Self.completion
        // Fragment the response mid-field to verify forwarding preserves the byte stream.
        client?.urlProtocol(self, didLoad: Data(data.prefix(7)))
        client?.urlProtocol(self, didLoad: Data(data.dropFirst(7)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
