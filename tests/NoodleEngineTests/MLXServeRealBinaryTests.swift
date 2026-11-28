import Darwin
import Foundation
import Testing
@testable import NoodleCore

/// Real pinned binary, real weights, real Metal: run outside the sandbox with nothing else heavy running.
///
///     NOODLE_MLX_REAL=1 NOODLE_MLX_HOME=/path/to/mlx-real \
///       NOODLE_MLX_ARCHIVE=<mlx-serve-bin-macos-arm64.tar.gz> \
///       NOODLE_MLX_GGUF=<existing text model.gguf> \
///       swift test --filter MLXServeRealBinaryTests
///
/// `NOODLE_MLX_HOME/models/weights/qwen3-0.6b-mlx.mlx` must exist (`NOODLE_HOME=... noodle model pull qwen3-0.6b-mlx`).
/// The archive is installed through the same verify-and-extract path the first-use download uses; only the
/// transport differs, because the product download is https-only.
@Suite(.tags(.slow), .serialized, .enabled(if: ProcessInfo.processInfo.environment["NOODLE_MLX_REAL"] == "1"))
struct MLXServeRealBinaryTests {
    private let id = "qwen3-0.6b-mlx"

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        try #require(bound)
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func request(_ path: String, port: Int, key: String?, anthropic: Bool = false, body: [String: Any]? = nil) async throws
        -> (status: Int, data: Data, seconds: Double) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 120
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key {
            if anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let start = Date()
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data, Date().timeIntervalSince(start))
    }

    @Test func installsServesAndCachesUnderTheNoodleHome() async throws {
        let home = URL(fileURLWithPath: try #require(environment["NOODLE_MLX_HOME"]), isDirectory: true)
        let models = home.appendingPathComponent("models", isDirectory: true)
        let archive = URL(fileURLWithPath: try #require(environment["NOODLE_MLX_ARCHIVE"]))
        let weights = models.appendingPathComponent("weights/\(id).mlx", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: weights.path), "pull \(id) into NOODLE_MLX_HOME first")
        let gguf = URL(fileURLWithPath: try #require(environment["NOODLE_MLX_GGUF"]))
        try #require(FileManager.default.fileExists(atPath: gguf.path))

        let binary = try MLXServeRuntime.install(archive: archive, into: models)
        let key = IDs.random64()
        let port = try freePort()
        _ = try MLXServeLaunch.modelLink(id: id, weights: weights, in: models)
        let ggufID = "gguf-fixture"
        _ = try MLXServeLaunch.modelLink(id: ggufID, weights: gguf, in: models)
        for folder in MLXServeLaunch.modelDirectories(in: models) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = Array(MLXServeLaunch.arguments(executable: binary.path, modelDirectories: MLXServeLaunch.modelDirectories(in: models), host: "127.0.0.1", port: port,
                                                           idleEvictSeconds: 300, physicalMemory: ProcessInfo.processInfo.physicalMemory).dropFirst())
        let variables = try MLXServeLaunch.environment(models: models, key: key)
        process.environment = environment.filter { !$0.key.hasPrefix("MLX_SERVE_") }.merging(variables.set) { $1 }
        let log = home.appendingPathComponent("mlx-serve.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { stop(process) }

        var ready = false
        for _ in 0..<240 where process.isRunning {
            if let reply = try? await request("/v1/models", port: port, key: key), reply.status == 200,
               String(decoding: reply.data, as: UTF8.self).contains("\"\(id)\"") { ready = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        try #require(ready, "runtime did not list \(id); see \(log.path)")
        let loaded = try await request("/v1/load-model", port: port, key: key, body: ["model": id, "default": true])
        try #require(loaded.status == 200, "preload failed: \(String(decoding: loaded.data, as: UTF8.self))")

        // Localhost is not exempt: no key, no answer.
        #expect(try await request("/v1/models", port: port, key: nil).status == 401)
        #expect(try await request("/v1/models", port: port, key: "wrong").status == 401)

        // OpenAI chat, streamed.
        var streaming = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        streaming.httpMethod = "POST"
        streaming.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        streaming.setValue("application/json", forHTTPHeaderField: "Content-Type")
        streaming.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": id, "stream": true, "max_tokens": 16, "temperature": 0,
            "messages": [["role": "user", "content": "Say hello."]], "chat_template_kwargs": ["enable_thinking": false]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (bytes, response) = try await URLSession(configuration: configuration).bytes(for: streaming)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var events = 0, done = false
        for try await line in bytes.lines where line.hasPrefix("data:") {
            if line.contains("[DONE]") { done = true } else { events += 1 }
        }
        #expect(events > 0 && done)

        // Anthropic messages on the same endpoint, key in x-api-key.
        let messages = try await request("/v1/messages", port: port, key: key, anthropic: true, body: [
            "model": id, "max_tokens": 16, "messages": [["role": "user", "content": "Say hello."]]])
        #expect(messages.status == 200)
        let anthropic = try #require(JSONSerialization.jsonObject(with: messages.data) as? [String: Any])
        #expect(anthropic["content"] is [Any])

        // A repeated long prompt is served from the prefix cache the second time.
        _ = try await request("/v1/chat/completions", port: port, key: key, body: [
            "model": id, "max_tokens": 1, "messages": [["role": "user", "content": "warm up"]]])
        let long = UUID().uuidString + " " + (1...140).map { "Item \($0) of the inventory covers part \($0 * 7) of the harbour ledger." }.joined(separator: " ")
        let body: [String: Any] = ["model": id, "max_tokens": 1, "temperature": 0,
                                   "messages": [["role": "user", "content": long]]]
        let first = try await request("/v1/chat/completions", port: port, key: key, body: body)
        let second = try await request("/v1/chat/completions", port: port, key: key, body: body)
        #expect(first.status == 200 && second.status == 200, "\(first.status) \(String(decoding: first.data.prefix(400), as: UTF8.self)) | \(second.status)")
        func cached(_ data: Data) -> Int {
            let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"] as? [String: Any]
            return (usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        }
        // The chat template's shared prefix may already be cached; the repeat must reuse far more.
        #expect(cached(second.data) > cached(first.data) + 1000, "cached \(cached(first.data)) then \(cached(second.data))")
        #expect(second.seconds < first.seconds, "second \(second.seconds)s should beat first \(first.seconds)s")

        // The SSD tier writes under the Noodle home, and nothing lands in the user's own home folder.
        let cache = MLXServeLaunch.cacheDirectory(in: models)
        var files = 0
        for _ in 0..<60 where files == 0 {
            files = FileManager.default.enumerator(atPath: cache.path)?.allObjects.count ?? 0
            if files == 0 { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(files > 0, "no kv-cache files under \(cache.path)")

        // The same authenticated process serves the embedded GGUF engine as well.
        let ggufLoaded = try await request("/v1/load-model", port: port, key: key,
                                           body: ["model": ggufID, "default": true])
        try #require(ggufLoaded.status == 200, "GGUF preload failed: \(String(decoding: ggufLoaded.data, as: UTF8.self))")
        let ggufReply = try await request("/v1/chat/completions", port: port, key: key, body: [
            "model": ggufID, "max_tokens": 16, "messages": [["role": "user", "content": "Say hello."]]])
        #expect(ggufReply.status == 200)
        let unloaded = try await request("/v1/unload-model", port: port, key: key, body: ["model": ggufID])
        #expect(unloaded.status == 200)
        let reloaded = try await request("/v1/load-model", port: port, key: key, body: ["model": id, "default": true])
        #expect(reloaded.status == 200)
        #expect(process.isRunning)
    }
}
