import Foundation
import NoodleCore
import NoodleImages

extension DockerModelRunner {
    struct Receipt: Codable, Sendable {
        var localID: String
        var model: DockerModelRunnerContract.Model
        var weightsDigest: String? = nil
    }

    public static func disk<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private var receiptURL: URL { home.appendingPathComponent("models/docker-models.json") }

    func receipts() async throws -> [Receipt] {
        let url = receiptURL
        return try await Self.disk {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: url))
        }
    }

    private func saveReceipts(_ receipts: [Receipt]) async throws {
        let url = receiptURL
        try await Self.disk {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(receipts).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func removeReceipt(localID: String) async throws {
        let saved = try await receipts()
        try await saveReceipts(saved.filter { $0.localID != localID })
        let metadata = home.appendingPathComponent("models/docker/" + localID)
        try await Self.disk {
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        }
    }

    func removeTag(_ tag: String, localID: String) async throws {
        var saved = try await receipts()
        guard let index = saved.firstIndex(where: { $0.localID == localID }) else {
            throw DockerModelRunnerError(404, "Model tag not found")
        }
        saved[index].model.tags.removeAll { $0 == tag }
        try await saveReceipts(saved)
    }

    static func hubReference(_ reference: String) throws -> ImageReference {
        let ref: ImageReference
        do { ref = try ImageReference.parse(reference.contains("/") ? reference : "ai/" + reference) }
        catch { throw DockerModelRunnerError(400, "Invalid OCI model reference") }
        guard ref.domain == ImageReference.hubDomain, ref.path.hasPrefix("ai/") else {
            throw DockerModelRunnerError(422, "OCI model pulls support Docker Hub ai/* single-file GGUF artifacts; public hf.co references are also supported")
        }
        return ref
    }

    /// Docker model layers are raw files, not container rootfs tar layers.
    /// Reject sidecars that cannot be represented by the CLI's single-GGUF import.
    static func ggufLayer(_ manifest: Manifest) throws -> (config: Descriptor, weights: Descriptor, licenses: [Descriptor]) {
        guard manifest.schemaVersion == 2, let config = manifest.config,
              ["application/vnd.docker.ai.model.config.v0.1+json", "application/vnd.docker.ai.model.config.v0.2+json"].contains(config.mediaType),
              Digest.isValid(config.digest), config.size > 0, config.size <= 1 << 20,
              let layers = manifest.layers, !layers.isEmpty else {
            throw DockerModelRunnerError(422, "Unsupported OCI model config")
        }
        let weights = layers.filter { $0.mediaType == "application/vnd.docker.ai.gguf.v3" }
        guard weights.count == 1, layers.allSatisfy({
            Digest.isValid($0.digest) && $0.size > 0 &&
            ($0.mediaType == "application/vnd.docker.ai.gguf.v3" && $0.size <= 64 << 30 ||
             $0.mediaType == "application/vnd.docker.ai.license" && $0.size <= 1 << 20)
        }) else {
            throw DockerModelRunnerError(422, "Only one raw GGUF layer plus optional licenses is supported; split weights, projectors, templates and Safetensors artifacts cannot be imported")
        }
        return (config, weights[0], layers.filter { $0.mediaType == "application/vnd.docker.ai.license" })
    }

    func pullOCI(_ reference: String) async throws {
        let ref = try Self.hubReference(reference)
        if let existing = try await receipts().first(where: { $0.model.tags.contains(ref.familiar) }) {
            let weights = ModelLocation.weights(root: home).appendingPathComponent(existing.localID + ".gguf")
            if try await Self.disk({ FileManager.default.fileExists(atPath: weights.path) }) {
                guard let expected = existing.weightsDigest, Digest.isValid(expected) else {
                    throw DockerModelRunnerError(422, "Installed OCI model is missing its weights checksum")
                }
                guard try await Self.disk({ try Digest.sha256(file: weights) == expected }) else {
                    throw DockerModelRunnerError(422, "Installed OCI weights failed checksum verification; remove the model before retrying")
                }
                return
            }
            // Models removed through the native UI/CLI must be pullable again through Docker.
            try await removeReceipt(localID: existing.localID)
        }
        let work = home.appendingPathComponent("models/.docker-pull-" + UUID().uuidString)
        let paths = NoodlePaths(root: work)
        let blobs = try await Self.disk { BlobStore(paths: paths) }
        let registry = RegistryClient(tempDirectory: paths.tmpDir)
        do {
            var response = try await registry.manifest(ref)
            if MediaType.isIndex(response.mediaType) {
                let index = try JSONDecoder().decode(Manifest.self, from: response.data)
                let candidates = (index.manifests ?? []).filter { $0.mediaType == MediaType.ociManifest &&
                    ($0.platform == nil || $0.platform?.architecture == "arm64" || $0.platform?.architecture == "unknown") }
                guard candidates.count == 1, Digest.isValid(candidates[0].digest) else {
                    throw DockerModelRunnerError(422, "OCI model index must identify one compatible GGUF manifest")
                }
                response = try await registry.manifest(ref, reference: candidates[0].digest)
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: response.data)
            let selected = try Self.ggufLayer(manifest)
            for descriptor in [selected.config, selected.weights] + selected.licenses {
                try await registry.fetchBlob(ref, digest: descriptor.digest, expectedSize: descriptor.size, into: blobs)
                guard try await Self.disk({ blobs.size(descriptor.digest) }) == descriptor.size else {
                    throw DockerModelRunnerError(422, "OCI model descriptor size mismatch")
                }
            }
            struct ConfigFile: Decodable {
                struct Config: Decodable { let format: String }
                let config: Config
            }
            let configBytes = try await Self.disk { try blobs.read(selected.config.digest) }
            guard try JSONDecoder().decode(ConfigFile.self, from: configBytes).config.format == "gguf" else {
                throw DockerModelRunnerError(422, "OCI model config is not GGUF")
            }
            let localID = "dmr-" + selected.weights.digest.dropFirst(7).prefix(48)
            let source = work.appendingPathComponent("model.gguf")
            try await Self.disk { try FileManager.default.copyItem(at: blobs.url(selected.weights.digest), to: source) }
            // CLI import validates the GGUF header and installs through the same operation lock as native pulls.
            let installed = try JSONDecoder().decode([LocalModel].self, from: await command(["list", "--json"]))
            if installed.contains(where: { $0.id == localID }) {
                let weights = ModelLocation.weights(root: home).appendingPathComponent(localID + ".gguf")
                guard try await Self.disk({ try Digest.sha256(file: weights) == selected.weights.digest }) else {
                    throw DockerModelRunnerError(422, "Installed OCI weights failed checksum verification")
                }
            } else { _ = try await command(["import", source.path, localID]) }
            let model = Model(id: selected.config.digest, tags: [ref.familiar], created: 0,
                              config: .init(format: "gguf", size: String(selected.weights.size), context_size: nil))
            var saved = try await receipts()
            // Reuse one imported weights file for aliases that resolve to the same layer.
            if let existing = saved.firstIndex(where: { $0.localID == localID }) {
                if !saved[existing].model.tags.contains(ref.familiar) { saved[existing].model.tags.append(ref.familiar) }
            } else { saved.append(.init(localID: localID, model: model, weightsDigest: selected.weights.digest)) }
            let licenses = try await Self.disk {
                try selected.licenses.map { (digest: $0.digest, data: try blobs.read($0.digest)) }
            }
            let metadata = home.appendingPathComponent("models/docker/" + localID)
            try await Self.disk {
                try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try configBytes.write(to: metadata.appendingPathComponent("config.json"), options: .atomic)
                for license in licenses {
                    try license.data.write(to: metadata.appendingPathComponent("license-" + license.digest.dropFirst(7)), options: .atomic)
                }
            }
            try await saveReceipts(saved)
            try await Self.disk { try FileManager.default.removeItem(at: work) }
        } catch {
            try? await Self.disk { try FileManager.default.removeItem(at: work) }
            throw error
        }
    }
}
