import Foundation

extension ModelStore {
    /// Folders a pack may carry one level down, with the only extensions each may hold: Kokoro's phoneme tables,
    /// the FLUX.2 parts and LTX's text encoder. Python code and symlinks are never imported.
    static let mlxSubfolders: [String: Set<String>] = [
        "g2p": ["json"],
        "text_encoder": ["safetensors", "json"], "transformer": ["safetensors", "json"], "vae": ["safetensors", "json"],
        "tokenizer": ["json", "jinja"], "gemma4-12b-ltx-v1": ["safetensors", "json", "jinja"],
    ]

    func mlxRelativePath(_ file: URL, in directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
    }

    /// Local model inputs: a flat folder, plus the allowed subfolders in `mlxSubfolders`.
    func mlxFiles(_ directory: URL) throws -> [URL] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CLIError("expected an MLX model folder")
        }
        let allowed = Set(["json", "safetensors", "txt", "model", "jinja", "tiktoken", "md"])
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        guard items.count <= 10_000 else { throw CLIError("the model folder contains too many files") }
        func regular(_ item: URL) throws -> Bool {
            let info = try item.resourceValues(forKeys: Set(keys))
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw CLIError("model inputs must be regular files: \(item.lastPathComponent)")
            }
            return true
        }
        var found: [URL] = []
        for item in items {
            let info = try item.resourceValues(forKeys: Set(keys))
            if info.isDirectory == true, info.isSymbolicLink != true, let exts = Self.mlxSubfolders[item.lastPathComponent] {
                let inner = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: keys)
                guard inner.count <= 100 else { throw CLIError("the model folder contains too many files") }
                for file in inner where exts.contains(file.pathExtension) {
                    if try regular(file) { found.append(file) }
                }
            } else if allowed.contains(item.pathExtension) || item.lastPathComponent == "LICENSE" {
                if try regular(item) { found.append(item) }
            }
        }
        return found
    }

    func mlxSize(_ directory: URL) throws -> UInt64 {
        try mlxFiles(directory).reduce(UInt64(0)) { total, file in
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let (next, overflow) = total.addingReportingOverflow(UInt64(max(0, size)))
            guard !overflow else { throw CLIError("the model folder is too large") }
            return next
        }
    }

    func checkMLX(_ directory: URL) throws {
        let inputs = try mlxFiles(directory)
        let names = Set(inputs.map { mlxRelativePath($0, in: directory) })
        guard names.contains("config.json"), names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw CLIError("MLX imports need config.json, a tokenizer and .safetensors weights")
        }
        func object(_ name: String) throws -> [String: Any] {
            let url = directory.appendingPathComponent(name)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 4 * 1_024 * 1_024,
                  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CLIError("invalid MLX metadata: \(name)")
            }
            return object
        }
        guard let modelType = try object("config.json")["model_type"] as? String, !modelType.isEmpty else {
            throw CLIError("MLX config.json is missing model_type")
        }
        // Kokoro reads phonemes, not a tokenizer. Qwen3-ASR ships vocab.json and merges.txt instead of tokenizer.json.
        // FLUX.2 and LTX keep the tokenizer in a subfolder.
        let tokenizer = names.contains { $0 == "tokenizer.json" || $0.hasSuffix("/tokenizer.json") } || names.contains("tokenizer.model")
            || names.isSuperset(of: ["vocab.json", "merges.txt"])
        if modelType == "kokoro" {
            guard names.isSuperset(of: ["model.safetensors", "voices.safetensors"]) else {
                throw CLIError("Kokoro imports need model.safetensors and voices.safetensors")
            }
        } else if !tokenizer {
            throw CLIError("MLX imports need config.json, a tokenizer and .safetensors weights")
        }
        if names.contains("model.safetensors.index.json") {
            guard let map = try object("model.safetensors.index.json")["weight_map"] as? [String: String], !map.isEmpty else {
                throw CLIError("invalid MLX weight index")
            }
            for file in Set(map.values) {
                guard !file.contains("/"), file.hasSuffix(".safetensors"), names.contains(file) else {
                    throw CLIError("MLX weight index references an unavailable file")
                }
            }
        }
    }

    func checkWeights(_ url: URL) throws {
        if isExternal(url) { try checkExternal(url) } else if url.pathExtension == "mlx" { try checkMLX(url) } else { try checkGGUF(url) }
    }
}
