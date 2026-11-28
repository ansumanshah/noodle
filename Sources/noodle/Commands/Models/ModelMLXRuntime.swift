import Darwin
import Foundation
import NoodleCore

/// First-use download and launch of the one engine for GGUF and MLX models.
enum ModelMLXRuntime {
    static func executable(store: ModelStore) throws -> URL {
        let pin = MLXServeRuntime.pin
        if let binary = MLXServeRuntime.executable(in: store.directory) {
            MLXServeRuntime.removeSuperseded(in: store.directory)
            return binary
        }
        do {
            return try store.stage { staging in
                let archive = staging.appendingPathComponent("mlx-serve.tar.gz")
                err("Downloading MLX support (\(pin.size) bytes)")
                try store.download(pin.url, to: archive, sha256: pin.sha256, totalBytes: pin.size)
                return try MLXServeRuntime.install(archive: archive, into: store.directory)
            }
        } catch {
            throw MLXServeRuntime.downloadFailure(pin, error.localizedDescription)
        }
    }

    static func prepareModels(store: ModelStore) throws {
        for folder in MLXServeLaunch.modelDirectories(in: store.directory) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // A borrowed model that was deleted leaves a dangling link behind.
        for case let url as URL in MLXServeLaunch.modelDirectories(in: store.directory).compactMap({ FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil) }).joined()
        where (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil && !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        for model in store.list(includeCatalog: false) {
            _ = try MLXServeLaunch.modelLink(id: model.id, weights: store.path(for: model.id), in: store.directory)
        }
    }

    static func arguments(executable: String, host: String, port: Int,
                          keepAlive: LocalModelKeepAlive, backend: LocalModelBackend, store: ModelStore) throws -> [String] {
        try prepareModels(store: store)
        return MLXServeLaunch.arguments(executable: executable, modelDirectories: MLXServeLaunch.modelDirectories(in: store.directory),
                                        host: host, port: port, idleEvictSeconds: try keepAlive.idleEvictSeconds(),
                                        physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                        network: ModelNetworkSetting.enabled(root: store.directory.deletingLastPathComponent()), backend: backend)
    }

    /// Call right before exec, after anything in this process has read the real HOME.
    static func applyEnvironment(key: String, store: ModelStore) throws {
        let variables = try MLXServeLaunch.environment(models: store.directory, key: key)
        for name in env.keys where variables.clearPrefixes.contains(where: { name.hasPrefix($0) }) { unsetenv(name) }
        for (name, value) in variables.set {
            guard setenv(name, value, 1) == 0 else { throw modelPOSIXError() }
        }
    }
}
