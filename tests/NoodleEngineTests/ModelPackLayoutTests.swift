import Foundation
import Testing
@testable import noodle
import NoodleCore

@Suite struct ModelPackLayoutTests {
    private func store() throws -> (ModelStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ModelStore(directory: root), root)
    }

    /// Builds a pack folder from relative names; `config.json` defaults to a model_type of `type`.
    private func pack(_ root: URL, type: String, _ names: [String]) throws -> URL {
        let dir = root.appendingPathComponent("pack.mlx", isDirectory: true)
        for name in names + ["config.json"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((name == "config.json" ? #"{"model_type":"\#(type)"}"# : "{}").utf8).write(to: url)
        }
        return dir
    }

    @Test func chatEmbeddingAndSpeechToTextPacksPass() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        try store.checkMLX(try pack(root, type: "qwen3", ["tokenizer.json", "model.safetensors"]))
        try FileManager.default.removeItem(at: root.appendingPathComponent("pack.mlx"))
        // Qwen3-ASR has vocab.json and merges.txt instead of tokenizer.json.
        try store.checkMLX(try pack(root, type: "qwen3_asr", ["vocab.json", "merges.txt", "model.safetensors", "preprocessor_config.json"]))
    }

    @Test func kokoroPackNeedsItsVoicesAndAllowsG2PTables() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["model.safetensors", "voices.safetensors", "g2p/us_gold.json"]
        let dir = try pack(root, type: "kokoro", names)
        try store.checkMLX(dir)
        #expect(try store.mlxFiles(dir).map { store.mlxRelativePath($0, in: dir) }.contains("g2p/us_gold.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("voices.safetensors"))
        #expect(throws: CLIError.self) { try store.checkMLX(dir) }
    }

    @Test func packWithoutATokenizerIsRefused() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CLIError.self) { try store.checkMLX(try pack(root, type: "qwen3", ["vocab.json", "model.safetensors"])) }
    }

    @Test func otherSubfoldersAndWrongFilesInsideAreIgnored() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try pack(root, type: "kokoro", ["model.safetensors", "voices.safetensors", "g2p/tool.py", "g2p/x.safetensors",
                                                   "extra/evil.json", "run.py", "weights.bin", "voices/af.pt"])
        let found = Set(try store.mlxFiles(dir).map { store.mlxRelativePath($0, in: dir) })
        #expect(found == ["config.json", "model.safetensors", "voices.safetensors"])
    }

    @Test func symlinksAreRefusedTopLevelAndInsideG2P() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        let dir = try pack(root, type: "kokoro", ["model.safetensors", "voices.safetensors", "g2p/ok.json"])
        let inner = dir.appendingPathComponent("g2p/link.json")
        try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: outside)
        #expect(throws: CLIError.self) { try store.mlxFiles(dir) }
        try FileManager.default.removeItem(at: inner)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("tokenizer.json"), withDestinationURL: outside)
        #expect(throws: CLIError.self) { try store.mlxFiles(dir) }
    }

    @Test func symlinkedG2PFolderIsNotFollowed() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try pack(root, type: "kokoro", ["model.safetensors", "voices.safetensors"])
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: target.appendingPathComponent("a.json"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("g2p"), withDestinationURL: target)
        #expect(!(try store.mlxFiles(dir)).contains { $0.path.contains("g2p") })
    }

    @Test func importCopiesTheG2PFolder() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try pack(root, type: "kokoro", ["model.safetensors", "voices.safetensors", "g2p/us_gold.json"])
        try store.importWeights(source, as: "my-kokoro")
        let installed = try store.path(for: "my-kokoro")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("g2p/us_gold.json").path))
    }

    private let fluxNames = ["text_encoder/0.safetensors", "text_encoder/model.safetensors.index.json", "tokenizer/tokenizer.json",
                             "tokenizer/chat_template.jinja", "transformer/0.safetensors", "vae/0.safetensors"]

    @Test func fluxPackWithWeightsAndTokenizerInSubfoldersPasses() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try pack(root, type: "flux2-klein-4b", fluxNames)
        try store.checkMLX(dir)
        try store.importWeights(dir, as: "my-flux")
        let installed = try store.path(for: "my-flux")
        for name in fluxNames { #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(name).path), "\(name)") }
    }

    @Test func fluxPackWithoutATokenizerIsRefused() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try pack(root, type: "flux2-klein-4b", fluxNames.filter { !$0.hasPrefix("tokenizer/") })
        #expect(throws: CLIError.self) { try store.checkMLX(dir) }
    }

    @Test func generationSubfoldersSkipCodeAndRefuseSymlinks() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try pack(root, type: "flux2-klein-4b", fluxNames + ["transformer/run.sh", "vae/hook.py", "tokenizer/x.safetensors"])
        let found = Set(try store.mlxFiles(dir).map { store.mlxRelativePath($0, in: dir) })
        #expect(found == Set(fluxNames + ["config.json"]))
        let outside = root.appendingPathComponent("outside.safetensors")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("transformer/1.safetensors"), withDestinationURL: outside)
        #expect(throws: CLIError.self) { try store.mlxFiles(dir) }
    }

    @Test func generationPacksAreCatalogedWithKindAndLicense() throws {
        let flux = try #require(ModelCatalog.entries["flux2-klein-4b"])
        #expect(flux.kind == .imageGeneration && flux.license == "Apache-2.0")
        let ltx = try #require(ModelCatalog.entries["ltx-2.5-video"])
        #expect(ltx.kind == .videoGeneration && ltx.license.hasPrefix("LicenseRef-"))
        // LTX does not fit a 16 GB Mac; FLUX.2 klein does.
        let sixteen: UInt64 = 16 << 30
        #expect(ModelMemoryFit(modelBytes: ltx.bytes, totalMemory: sixteen) == .tooBig)
        #expect(ModelMemoryFit(modelBytes: flux.bytes, totalMemory: sixteen) != .tooBig)
    }

    @Test func catalogEntriesAreWellFormed() {
        for (id, entry) in ModelCatalog.entries {
            #expect(ModelStore.validID(id))
            #expect(entry.baseURL.hasPrefix("https://huggingface.co/") && entry.baseURL.hasSuffix("/"))
            if entry.backend == .mlx {
                // A pinned 40-character commit, never a branch.
                let commit = entry.baseURL.components(separatedBy: "/resolve/").last?.dropLast() ?? ""
                #expect(commit.count == 40 && commit.allSatisfy(\.isHexDigit), "\(id) must pin a commit")
            }
            for file in entry.files {
                #expect(file.bytes > 0 && file.sha256.hasPrefix("sha256:") && file.sha256.count == 71, "\(id)/\(file.name)")
                #expect(!file.name.hasPrefix("/") && !file.name.contains(".."), "\(id)/\(file.name)")
                // Only the one-level subfolders the importer accepts.
                let parts = file.name.split(separator: "/")
                #expect(parts.count == 1 || (parts.count == 2 && ModelStore.mlxSubfolders[String(parts[0])]?.contains((file.name as NSString).pathExtension) == true))
            }
        }
    }

    @Test func apiModelsAreCatalogedWithKindAndLicense() throws {
        let expected: [String: LocalModelKind] = ["qwen3-embedding-0.6b": .embeddings, "qwen3-asr-0.6b": .speechToText, "kokoro-82m": .textToSpeech]
        for (id, kind) in expected {
            let entry = try #require(ModelCatalog.entries[id])
            #expect(entry.kind == kind && entry.backend == .mlx && entry.license == "Apache-2.0")
        }
        #expect(ModelCatalog.entries["gemma4"]?.kind == .chat)
        // The embedding pooling falls back to the folder name, so the id must keep the word.
        #expect(expected.first { $0.value == .embeddings }?.key.contains("embedding") == true)
    }

    @Test func listCarriesTheKindFromTheCatalog() throws {
        let (store, root) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let models = Dictionary(uniqueKeysWithValues: store.list(includeCatalog: true).map { ($0.id, $0.kind) })
        #expect(models["kokoro-82m"] == .textToSpeech && models["qwen3.5-2b"] == .chat && models["qwen3.5-4b"] == .chat)
    }
}
