import Foundation

/// How Noodle starts the MLX runtime. The runtime resolves its kv-cache, logs and plugin folder from
/// `$HOME/.mlx-serve` and offers no flag for them, so the child gets a private HOME under the model
/// store and nothing lands in the user's own home folder.
public enum MLXServeLaunch {
    /// The key travels in this variable, never on the command line (`ps` is world-readable).
    public static let keyVariable = "NOODLE_MODEL_API_KEY"
    public static let diskCacheGB = 2

    public static func home(in models: URL) -> URL { models.appendingPathComponent("mlx-home", isDirectory: true) }

    public static func cacheDirectory(in models: URL) -> URL {
        home(in: models).appendingPathComponent(".mlx-serve/kv-cache", isDirectory: true)
    }

    public static func modelDirectory(in models: URL) -> URL {
        home(in: models).appendingPathComponent("models", isDirectory: true)
    }

    public static func modelDirectories(in models: URL) -> [URL] {
        [modelDirectory(in: models), home(in: models).appendingPathComponent("huggingface", isDirectory: true)]
    }

    /// The engine discovers org/repo names. The CLI's hf.co prefix selects its pull transport.
    public static func modelID(_ id: String) -> String {
        id.hasPrefix("hf.co/") ? String(id.dropFirst(6)) : id
    }

    /// Discovery scans directories, including a directory containing a GGUF file.
    /// Links preserve Noodle's model store as the only copy of the weights.
    public static func modelLink(id: String, weights: URL, in models: URL) throws -> URL {
        let files = FileManager.default
        if id.hasPrefix("hf.co/") {
            _ = try LocalModelHuggingFace.Reference(id)
        } else if id.range(of: #"^[a-z0-9][a-z0-9.-]{0,62}$"#, options: .regularExpression) == nil {
            throw MLXServeError("invalid model ID")
        }
        // A local model named like a Hub organization must not become that organization's parent.
        let folder = modelDirectories(in: models)[id.hasPrefix("hf.co/") ? 1 : 0]
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = folder.appendingPathComponent(modelID(id))
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if weights.pathExtension == "gguf" {
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil { try files.removeItem(at: link) }
            try files.createDirectory(at: link, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try replaceLink(link.appendingPathComponent("model.gguf"), pointingAt: weights)
        } else {
            try replaceLink(link, pointingAt: weights)
        }
        return link
    }

    private static func replaceLink(_ link: URL, pointingAt weights: URL) throws {
        let files = FileManager.default
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) == weights.path { return }
        if files.fileExists(atPath: link.path) || (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try files.removeItem(at: link)
        }
        try files.createSymbolicLink(at: link, withDestinationURL: weights)
    }

    /// Coding agents send 15,000 to 25,000 tokens before the first word, so MLX gets room for them: its KV grows
    /// with use. GGUF reserves four full windows at load, so it keeps 4096, which is also the benchmark method.
    // shortcut: the process keeps the window it started with, so a GGUF model loaded into an MLX session
    // reserves the larger one; pass a per-model window when the runtime takes one.
    public static func contextTokens(for backend: LocalModelBackend) -> Int { backend == .mlx ? 32768 : 4096 }

    /// A 1/32 slice of RAM, 256 MB to 2 GB: half a gigabyte on this 16 GB Mac.
    public static func prefixCacheMB(physicalMemory: UInt64) -> Int {
        min(2048, max(256, Int(min(physicalMemory, UInt64(Int.max)) / 32 / 1_048_576)))
    }

    /// `idleEvictSeconds` is the keep-alive in whole seconds; nil keeps models loaded.
    public static func arguments(executable: String, modelDirectories: [URL], host: String, port: Int,
                                 idleEvictSeconds: UInt32?, physicalMemory: UInt64, network: Bool = false,
                                 backend: LocalModelBackend = .llamaCPP) -> [String] {
        var arguments = [executable] + modelDirectories.flatMap { ["--model-dir", $0.path] } + ["--serve",
                         // The runtime binds all interfaces unless told otherwise. Network access is the only wildcard bind;
                         // the key flags below stay on either way, so a non-loopback peer always needs the key.
                         "--host", network ? "0.0.0.0" : host, "--port", String(port),
                         "--api-key-env", keyVariable, "--api-key-strict",
                         "--prefix-cache-mem", "\(prefixCacheMB(physicalMemory: physicalMemory))MB",
                         "--prefix-cache-disk", "\(diskCacheGB)GB",
                         "--llama-cache-entries", "1",
                         // Upstream defaults to the model's maximum (8192 for GGUF, with 4 sequences).
                         "--ctx-size", String(contextTokens(for: backend)),
                         "--no-plugins", "--log-file", "off"]
        if let idleEvictSeconds, idleEvictSeconds > 0 {
            arguments += ["--idle-evict-secs", String(idleEvictSeconds)]
        }
        return arguments
    }

    /// Variables to set in the child, and the prefixes to clear first so a stray setting cannot change a run.
    public static func environment(models: URL, key: String) throws -> (set: [String: String], clearPrefixes: [String]) {
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else { throw MLXServeError("invalid model session key") }
        try FileManager.default.createDirectory(at: cacheDirectory(in: models), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return ([keyVariable: key, "HOME": home(in: models).path], ["MLX_SERVE_"])
    }
}
