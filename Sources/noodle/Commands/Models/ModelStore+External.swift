import CryptoKit
import Foundation
import NoodleCore

/// Models other tools already downloaded: LM Studio and the Hugging Face hub cache. Read-only, never copied.
/// shortcut: scans on every call (two or three directory levels, no hashing), cache it if lists get slow.
extension ModelStore {
    struct ExternalModel {
        let id: String
        let name: String
        let url: URL
        let backend: LocalModelBackend
        let bytes: UInt64
        let slug: String
        let prefix: String
    }

    /// Process-wide scan, so listing N models does not scan N times. The CLI is short-lived; `list` refreshes it.
    final class ExternalScan: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [String: [ExternalModel]] = [:]
        func get(_ key: String, refresh: Bool = false, _ scan: () -> [ExternalModel]) -> [ExternalModel] {
            lock.lock(); defer { lock.unlock() }
            if refresh || models[key] == nil { models[key] = scan() }
            return models[key] ?? []
        }
    }

    private static let lmPrefix = "lmstudio-"
    private static let hfPrefix = "hf-"

    private static var externalEnabled: Bool { ProcessInfo.processInfo.environment["NOODLE_MODEL_EXTERNAL"] != "0" }

    /// Same rules as mlx-serve: settings.json downloadsFolder, else ~/.lmstudio/models.
    static func lmStudioRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = env["HOME"] ?? NSHomeDirectory()
        var path = home + "/.lmstudio/models"
        if let data = FileManager.default.contents(atPath: home + "/.lmstudio/settings.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = json["downloadsFolder"] as? String, !folder.isEmpty {
            path = (folder as NSString).expandingTildeInPath
        }
        return existingDirectory(path)
    }

    /// Same order as huggingface_hub: HF_HUB_CACHE, HF_HOME/hub, XDG_CACHE_HOME/huggingface/hub, ~/.cache/huggingface/hub.
    static func huggingFaceRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return (raw as NSString).expandingTildeInPath
        }
        let path: String
        if let hub = value("HF_HUB_CACHE") { path = hub }
        else if let home = value("HF_HOME") { path = home + "/hub" }
        else if let xdg = value("XDG_CACHE_HOME") { path = xdg + "/huggingface/hub" }
        else { path = (env["HOME"] ?? NSHomeDirectory()) + "/.cache/huggingface/hub" }
        return existingDirectory(path)
    }

    private static func existingDirectory(_ path: String) -> URL? {
        // Touching another volume makes macOS ask for removable-volume access and blocks the scan until the user answers.
        // shortcut: caches on other volumes are skipped; add an opt-in setting if users ask to list them.
        if onOtherVolume(path) { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    /// Follows symlinks with readlink only (never stats the target), so the check itself cannot trigger the prompt.
    static func onOtherVolume(_ path: String) -> Bool {
        let fm = FileManager.default
        var components: [String] = []
        var pending = (path as NSString).standardizingPath.split(separator: "/").map(String.init)
        var hops = 0
        while !pending.isEmpty {
            let next = pending.removeFirst()
            let candidate = "/" + (components + [next]).joined(separator: "/")
            if candidate.hasPrefix("/Volumes/") { return true }
            if hops < 32, let target = try? fm.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                let absolute = target.hasPrefix("/") ? target : "/" + (components + [target]).joined(separator: "/")
                // Not standardizingPath here: it strips /private and would loop on /var -> private/var.
                pending = absolute.split(separator: "/").map(String.init).filter { $0 != "." } + pending
                components = []
            } else {
                components.append(next)
            }
        }
        return false
    }

    func externalRoots() -> [URL] {
        guard Self.externalEnabled else { return [] }
        return [Self.lmStudioRoot(), Self.huggingFaceRoot()].compactMap { $0 }
    }

    /// Every model store path lives under `directory` or the chosen weights folder; anything else is borrowed.
    func isExternal(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return ![directory, weights].contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    func externalModel(_ id: String) -> ExternalModel? {
        guard id.hasPrefix(Self.lmPrefix) || id.hasPrefix(Self.hfPrefix) else { return nil }
        let hf = id.hasPrefix(Self.hfPrefix)
        return externalCache.get(hf ? "hf" : "lm") { scanExternal(lmStudio: !hf, huggingFace: hf) }.first { $0.id == id }
    }

    func externalSource(_ id: String) -> String { id.hasPrefix(Self.lmPrefix) ? "LM Studio" : "the Hugging Face cache" }

    func checkExternal(_ url: URL) throws {
        let ok = url.pathExtension == "gguf" ? (try? checkGGUF(url)) != nil
            : externalRoots().contains { externalMLXSize(url, within: $0) != nil }
        guard ok else { throw CLIError("the borrowed model at \(url.path) is no longer readable") }
    }

    /// Fresh scan of both roots; also what later `externalModel` lookups reuse.
    func externalModels() -> [ExternalModel] {
        externalCache.get("all", refresh: true) { scanExternal(lmStudio: true, huggingFace: true) }
    }

    private func scanExternal(lmStudio: Bool, huggingFace: Bool) -> [ExternalModel] {
        guard Self.externalEnabled else { return [] }
        var found: [ExternalModel] = []
        if lmStudio, let root = Self.lmStudioRoot() { found += lmStudioModels(root) }
        if huggingFace, let root = Self.huggingFaceRoot() { found += huggingFaceCacheModels(root) }
        // Models that still collide all take a hash of their path, so none is dropped.
        let clashing = Dictionary(grouping: found, by: \.id).filter { $0.value.count > 1 }.keys
        return found.map { model in
            guard clashing.contains(model.id) else { return model }
            return ExternalModel(id: Self.externalID(model.prefix, model.slug, hash: model.slug + "\0" + model.url.path), name: model.name,
                                 url: model.url, backend: model.backend, bytes: model.bytes, slug: model.slug, prefix: model.prefix)
        }.sorted { $0.id < $1.id }
    }

    private func children(_ url: URL) -> [URL] {
        let items = (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Array(items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(2_000))
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func lmStudioModels(_ root: URL) -> [ExternalModel] {
        var out: [ExternalModel] = []
        for publisher in children(root) where isDirectory(publisher) {
            for folder in children(publisher) where isDirectory(folder) {
                let name = publisher.lastPathComponent + "/" + folder.lastPathComponent
                out += externalModels(in: folder, root: root, prefix: Self.lmPrefix, name: name)
            }
        }
        return out
    }

    private func huggingFaceCacheModels(_ root: URL) -> [ExternalModel] {
        var out: [ExternalModel] = []
        for repo in children(root) where repo.lastPathComponent.hasPrefix("models--") {
            let name = repo.lastPathComponent.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
            let main = (try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pinned = main.flatMap { $0.isEmpty || $0.contains("/") ? nil : snapshots.appendingPathComponent($0, isDirectory: true) }
            let newest = children(snapshots).filter(isDirectory).max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            guard let snapshot = pinned.flatMap({ isDirectory($0) ? $0 : nil }) ?? newest else { continue }
            out += externalModels(in: snapshot, root: root, prefix: Self.hfPrefix, name: name)
        }
        return out
    }

    /// One MLX model for the folder, else one model per GGUF file in it.
    private func externalModels(in folder: URL, root: URL, prefix: String, name: String) -> [ExternalModel] {
        func make(_ slug: String, _ label: String, _ url: URL, _ backend: LocalModelBackend, _ bytes: UInt64) -> ExternalModel? {
            let id = Self.externalID(prefix, slug)
            return Self.validID(id) ? ExternalModel(id: id, name: label, url: url, backend: backend, bytes: bytes, slug: slug, prefix: prefix) : nil
        }
        if let bytes = externalMLXSize(folder, within: root) {
            return [make(name, name, folder, .mlx, bytes)].compactMap { $0 }
        }
        return children(folder).compactMap { file in
            let stem = file.deletingPathExtension().lastPathComponent
            // Only the first shard of a split GGUF is a model.
            let shard = stem.range(of: #"-\d{5}-of-\d{5}$"#, options: .regularExpression)
            guard file.pathExtension.lowercased() == "gguf", !stem.lowercased().contains("mmproj"),
                  shard == nil || stem.contains("-00001-of-"),
                  let bytes = externalGGUFSize(file, within: root) else { return nil }
            return make(name + "/" + stem, name + " " + stem, file, .llamaCPP, bytes)
        }
    }

    /// Lowercase letters, digits and periods only, hyphen-separated, at most 63 characters.
    /// Names too long for the budget keep their head plus `-` and 6 hex of a SHA-256, so they stay distinct.
    static func externalID(_ prefix: String, _ slug: String, hash: String? = nil) -> String {
        var out = ""
        for ch in slug.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == ".") { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        let dash = CharacterSet(charactersIn: "-")
        let budget = 63 - prefix.count
        guard out.count > budget || hash != nil else { return prefix + out.trimmingCharacters(in: dash) }
        let digest = SHA256.hash(data: Data((hash ?? slug).utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        return prefix + String(out.prefix(budget - 7)).trimmingCharacters(in: dash) + "-" + digest
    }

    /// MLX weights carry `__metadata__.format == "mlx"` in the safetensors header; plain PyTorch exports do not.
    private func isMLXWeights(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8 else { return false }
        let length = lengthBytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length > 0, length <= 1 << 20, let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
              let json = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else { return false }
        return (json["__metadata__"] as? [String: Any])?["format"] as? String == "mlx"
    }

    private func contained(_ url: URL, in root: URL) -> URL? {
        let real = url.resolvingSymlinksInPath()
        return real.path.hasPrefix(root.path + "/") ? real : nil
    }

    private func externalGGUFSize(_ file: URL, within root: URL) -> UInt64? {
        guard let real = contained(file, in: root), (try? checkGGUF(real)) != nil,
              let size = try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return UInt64(size)
    }

    /// Mirrors checkMLX, but follows symlinks that stay inside `root` (Hugging Face snapshots link into blobs/).
    func externalMLXSize(_ folder: URL, within root: URL) -> UInt64? {
        guard contained(folder, in: root) != nil else { return nil }
        let allowed = Set(["json", "safetensors", "txt", "model", "jinja", "tiktoken", "md"])
        var names = Set<String>()
        var firstWeights: URL?
        var total: UInt64 = 0
        for item in children(folder) where allowed.contains(item.pathExtension) || item.lastPathComponent == "LICENSE" {
            guard let real = contained(item, in: root),
                  let info = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  info.isRegularFile == true else { return nil }
            names.insert(item.lastPathComponent)
            if item.pathExtension == "safetensors", firstWeights == nil { firstWeights = real }
            total += UInt64(max(0, info.fileSize ?? 0))
        }
        func object(_ name: String) -> [String: Any]? {
            guard let real = contained(folder.appendingPathComponent(name), in: root),
                  let size = try? real.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 4 << 20,
                  let data = try? Data(contentsOf: real) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard names.contains("config.json"), names.contains("tokenizer.json") || names.contains("tokenizer.model"),
              let weights = firstWeights, isMLXWeights(weights),
              (object("config.json")?["model_type"] as? String)?.isEmpty == false else { return nil }
        if names.contains("model.safetensors.index.json") {
            guard let map = object("model.safetensors.index.json")?["weight_map"] as? [String: String], !map.isEmpty,
                  map.values.allSatisfy({ !$0.contains("/") && names.contains($0) }) else { return nil }
        }
        return total
    }
}
