import Foundation
import Testing
@testable import NoodleCore

@Suite(.tags(.slow)) struct MLXServeLaunchTests {
    private let key = String(repeating: "a1", count: 32)
    private let model = URL(fileURLWithPath: "/models/mlx-home/models")

    private func arguments(host: String = "127.0.0.1", idle: UInt32? = 300, memory: UInt64 = 16 << 30) -> [String] {
        MLXServeLaunch.arguments(executable: "/runtime/mlx-serve", modelDirectories: [model], host: host, port: 11434,
                                 idleEvictSeconds: idle, physicalMemory: memory)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    @Test func bindsTheRequestedHostNeverTheWildcard() {
        for host in ["127.0.0.1", "192.168.64.1"] {
            let list = arguments(host: host)
            #expect(value(after: "--host", in: list) == host)
            #expect(!list.contains("0.0.0.0"))
        }
        #expect(value(after: "--port", in: arguments()) == "11434")
    }

    @Test func keyComesFromTheEnvironmentAndIsRequiredFromLoopback() {
        let list = arguments()
        #expect(value(after: "--api-key-env", in: list) == MLXServeLaunch.keyVariable)
        #expect(list.contains("--api-key-strict"))
        #expect(!list.contains("--api-key"))
        #expect(!list.contains(key))
    }

    @Test func servesTheModelDirectoryWithAutoSettings() {
        let list = arguments()
        #expect(list.first == "/runtime/mlx-serve")
        #expect(value(after: "--model-dir", in: list) == model.path)
        #expect(value(after: "--ctx-size", in: list) == "4096")
        let mlx = MLXServeLaunch.arguments(executable: "/r/mlx-serve", modelDirectories: [], host: "127.0.0.1", port: 1,
                                           idleEvictSeconds: nil, physicalMemory: 16 << 30, backend: .mlx)
        #expect(value(after: "--ctx-size", in: mlx) == "32768")
        #expect(!list.contains("--model"))
        #expect(value(after: "--llama-cache-entries", in: list) == "1")
        #expect(list.contains("--no-plugins"))
        #expect(value(after: "--log-file", in: list) == "off")
        #expect(!list.contains("--no-prevent-sleep"))
    }

    @Test(arguments: zip([8, 16, 64, 1].map { UInt64($0) << 30 }, [256, 512, 2048, 256]))
    func prefixCacheScalesWithMemory(memory: UInt64, megabytes: Int) {
        #expect(MLXServeLaunch.prefixCacheMB(physicalMemory: memory) == megabytes)
        #expect(value(after: "--prefix-cache-mem", in: arguments(memory: memory)) == "\(megabytes)MB")
        #expect(value(after: "--prefix-cache-disk", in: arguments(memory: memory)) == "2GB")
    }

    @Test func keepAliveMapsToIdleEviction() {
        #expect(value(after: "--idle-evict-secs", in: arguments(idle: 300)) == "300")
        #expect(value(after: "--idle-evict-secs", in: arguments(idle: 1)) == "1")
        #expect(!arguments(idle: nil).contains("--idle-evict-secs"))
    }

    @Test func childGetsAPrivateHomeSoCachesStayUnderTheStore() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: models) }
        let environment = try MLXServeLaunch.environment(models: models, key: key)
        #expect(environment.set["HOME"] == models.appendingPathComponent("mlx-home").path)
        #expect(environment.set[MLXServeLaunch.keyVariable] == key)
        #expect(environment.clearPrefixes == ["MLX_SERVE_"])
        #expect(MLXServeLaunch.cacheDirectory(in: models).path == models.path + "/mlx-home/.mlx-serve/kv-cache")
        #expect(FileManager.default.fileExists(atPath: MLXServeLaunch.cacheDirectory(in: models).path))
        for bad in ["", "short", String(repeating: "z", count: 64), key + "0"] {
            #expect(throws: MLXServeError.self) { try MLXServeLaunch.environment(models: models, key: bad) }
        }
    }

    @Test func modelLinkPointsAtTheStoreAndIsReplaced() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: models) }
        let weights = models.appendingPathComponent("weights/qwen3-0.6b-mlx.mlx", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        let first = try MLXServeLaunch.modelLink(id: "qwen3-0.6b-mlx", weights: weights, in: models)
        let second = try MLXServeLaunch.modelLink(id: "qwen3-0.6b-mlx", weights: weights, in: models)
        #expect(first == second)
        #expect(first.lastPathComponent == "qwen3-0.6b-mlx")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: first.path) == weights.path)
    }

    @Test func ggufAndHubModelsAreDiscoverableWithoutCopyingWeights() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-gguf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: models) }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let weights = models.appendingPathComponent("model.gguf")
        try Data("GGUF".utf8).write(to: weights)
        for id in ["gemma4", "hf.co/Fixture/Repo:Q4_K_M"] {
            let link = try MLXServeLaunch.modelLink(id: id, weights: weights, in: models)
            let folder = MLXServeLaunch.modelDirectories(in: models)[id.hasPrefix("hf.co/") ? 1 : 0]
            #expect(link.path == folder.appendingPathComponent(MLXServeLaunch.modelID(id)).path)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.appendingPathComponent("model.gguf").path) == weights.path)
        }
        #expect(MLXServeLaunch.modelID("hf.co/Fixture/Repo:Q4_K_M") == "Fixture/Repo:Q4_K_M")
        let mlx = models.appendingPathComponent("weights/fixture.mlx")
        try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: true)
        _ = try MLXServeLaunch.modelLink(id: "fixture", weights: mlx, in: models)
        _ = try MLXServeLaunch.modelLink(id: "hf.co/fixture/Repo:Q4_K_M", weights: weights, in: models)
        #expect(!FileManager.default.fileExists(atPath: mlx.appendingPathComponent("Repo:Q4_K_M").path))
        for bad in ["../escape", "/absolute", "hf.co/../escape:Q4_K_M"] {
            #expect(throws: (any Error).self) { try MLXServeLaunch.modelLink(id: bad, weights: weights, in: models) }
        }
    }
}

@Suite struct ModelNetworkTests {
    private func models() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("net-\(UUID().uuidString)/models") }
    private func argv(network: Bool, host: String = "127.0.0.1") -> [String] {
        MLXServeLaunch.arguments(executable: "/r/mlx-serve", modelDirectories: [], host: host, port: 11345,
                                 idleEvictSeconds: nil, physicalMemory: 16 << 30, network: network)
    }

    @Test func networkBindsAllInterfacesAndKeepsKeyFlags() {
        for network in [true, false] {
            let list = argv(network: network, host: "192.168.64.1")
            #expect(list[list.firstIndex(of: "--host")! + 1] == (network ? "0.0.0.0" : "192.168.64.1"))
            #expect(list.contains("--api-key-strict") && list.contains("--api-key-env"))
        }
        #expect(argv(network: false)[argv(network: false).firstIndex(of: "--host")! + 1] == "127.0.0.1")
    }

    @Test func settingDefaultsOffAndPersists() throws {
        let models = models()
        let root = models.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ModelNetworkSetting.enabled(root: root))
        try ModelNetworkSetting.set(true, root: root)
        #expect(ModelNetworkSetting.enabled(root: root))
        try ModelNetworkSetting.set(false, root: root)
        #expect(!ModelNetworkSetting.enabled(root: root))
    }

    @Test func keyPersistsRotatesAndStaysPrivate() throws {
        let models = models()
        defer { try? FileManager.default.removeItem(at: models.deletingLastPathComponent()) }
        let first = try ModelAPIKey.current(in: models)
        #expect(first.count == 64)
        #expect(try ModelAPIKey.current(in: models) == first)
        let second = try ModelAPIKey.rotate(in: models)
        #expect(second != first)
        #expect(try ModelAPIKey.current(in: models) == second)
        #expect(try String(contentsOf: ModelAPIKey.headerFile(in: models), encoding: .utf8) == "Authorization: Bearer \(second)\n")
        for url in [ModelAPIKey.keyFile(in: models), ModelAPIKey.headerFile(in: models)] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }
}
