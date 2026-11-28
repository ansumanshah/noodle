import Darwin
import Foundation
import NoodleCore

struct ModelStore {
    let directory: URL
    let files = FileManager.default
    let externalCache = ExternalScan()
    /// A folder the user chose for weights (`ModelLocation`); nil keeps them in `<directory>/weights`.
    var customWeights: URL? = nil
    var weights: URL { customWeights ?? directory.appendingPathComponent("weights", isDirectory: true) }
    /// Staging and partial downloads sit on the same volume as the weights so installs stay a rename.
    var scratch: URL { customWeights ?? directory }

    func path(for id: String) throws -> URL {
        if id.hasPrefix("hf.co/") {
            let reference = try LocalModelHuggingFace.Reference(id)
            let target = huggingFacePath(for: reference)
            if files.fileExists(atPath: target.deletingLastPathComponent().path) {
                _ = try huggingFaceReceipt(at: target.deletingLastPathComponent(), for: reference)
            }
            return target
        }
        guard Self.validID(id) else {
            throw CLIError.usage("use a model ID of up to 63 lowercase letters, digits, periods, and hyphens, starting with a letter or digit")
        }
        let mlx = weights.appendingPathComponent(id + ".mlx", isDirectory: true)
        let gguf = weights.appendingPathComponent(id + ".gguf")
        if !files.fileExists(atPath: gguf.path), !files.fileExists(atPath: mlx.path), let borrowed = externalModel(id) { return borrowed.url }
        // A newly introduced catalog ID must not hide a user's existing import.
        if files.fileExists(atPath: gguf.path) { return gguf }
        return files.fileExists(atPath: mlx.path) || ModelCatalog.entries[id]?.backend == .mlx ? mlx : gguf
    }

    func backend(for id: String) throws -> LocalModelBackend {
        let url = try path(for: id)
        return (isExternal(url) ? url.pathExtension != "gguf" : url.pathExtension == "mlx") ? .mlx : .llamaCPP
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9.-]{0,62}$"#, options: .regularExpression) == id.startIndex..<id.endIndex
    }

    func list(includeCatalog: Bool) -> [LocalModel] {
        let installed = (try? files.contentsOfDirectory(at: weights, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])) ?? []
        var byID: [String: LocalModel] = [:]
        for url in installed where ["gguf", "mlx"].contains(url.pathExtension) {
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.validID(id), let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { continue }
            let backend: LocalModelBackend = url.pathExtension == "mlx" ? .mlx : .llamaCPP
            let size: UInt64
            if backend == .mlx {
                guard info.isDirectory == true, (try? checkMLX(url)) != nil,
                      let bytes = try? mlxSize(url) else { continue }
                size = bytes
            } else {
                guard info.isRegularFile == true, let bytes = info.fileSize, bytes >= 0 else { continue }
                size = UInt64(bytes)
            }
            let pin = ModelCatalog.entries[id].flatMap { $0.backend == backend ? $0 : nil }
            byID[id] = LocalModel(id: id, name: pin?.name ?? id, bytes: size,
                                  installed: true, downloadable: pin != nil, backend: backend, kind: pin?.kind ?? .chat)
        }
        for model in externalModels() where byID[model.id] == nil {
            byID[model.id] = LocalModel(id: model.id, name: model.name, bytes: model.bytes, installed: true, downloadable: false, backend: model.backend)
        }
        for model in huggingFaceModels() { byID[model.id] = model }
        if includeCatalog {
            for (id, pin) in ModelCatalog.entries where byID[id] == nil {
                byID[id] = LocalModel(id: id, name: pin.name, bytes: pin.bytes, installed: false, downloadable: true, backend: pin.backend, kind: pin.kind)
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    func pull(_ id: String, report: (@Sendable (LocalModelPullProgress) -> Void)? = nil) throws {
        if id.hasPrefix("hf.co/") {
            try pullHuggingFace(try LocalModelHuggingFace.Reference(id), report: report)
            return
        }
        let target = try path(for: id)
        guard let pin = ModelCatalog.entries[id] else {
                throw CLIError("model \(id) is outside the catalog. See 'noodle model catalog' or import local weights.")
        }
        if files.fileExists(atPath: target.path) {
            guard try backend(for: id) == pin.backend else {
                throw CLIError("\(id) already contains weights for another runtime. Keep that import under another ID before pulling this catalog entry.")
            }
            report?(.init(phase: .verifying, receivedBytes: pin.bytes, totalBytes: pin.bytes))
            for file in pin.files {
                let input = pin.backend == .mlx ? target.appendingPathComponent(file.name) : target
                guard try Digest.sha256(file: input) == file.sha256 else {
                    throw CLIError("installed weights differ from the catalog. Remove \(id) before pulling it again.")
                }
            }
        } else {
            try stage { staging in
                let downloaded = staging.appendingPathComponent(pin.backend == .mlx ? "model.mlx" : "model.gguf")
                if pin.backend == .mlx { try files.createDirectory(at: downloaded, withIntermediateDirectories: false) }
                err("Downloading \(pin.name) (\(pin.bytes) bytes)")
                var completed: UInt64 = 0
                for file in pin.files {
                    let offset = completed
                    let totalBytes = pin.bytes
                    let output = pin.backend == .mlx ? downloaded.appendingPathComponent(file.name) : downloaded
                    // A catalog file may sit one folder down (Kokoro's g2p tables).
                    if pin.backend == .mlx, file.name.contains("/") {
                        try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    let progress: (@Sendable (LocalModelPullProgress) -> Void)?
                    if let report {
                        progress = { event in
                            report(.init(phase: .downloading, receivedBytes: offset + event.receivedBytes, totalBytes: totalBytes))
                        }
                    } else { progress = nil }
                    try download(pin.baseURL + file.name, to: output, sha256: file.sha256, totalBytes: file.bytes, report: progress)
                    completed += file.bytes
                }
                report?(.init(phase: .verifying, receivedBytes: pin.bytes, totalBytes: pin.bytes))
                try install(downloaded, at: target)
            }
        }
        report?(.init(phase: .installed, receivedBytes: pin.bytes, totalBytes: pin.bytes))
    }

    func importWeights(_ input: URL, as id: String) throws {
        guard Self.validID(id) else {
            throw CLIError("imports need a local model ID; hf.co IDs are reserved for Hugging Face pulls")
        }
        let source = input.resolvingSymlinksInPath()
        let isMLX = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let target = try path(for: id).deletingPathExtension().appendingPathExtension(isMLX ? "mlx" : "gguf")
        guard ModelCatalog.entries[id] == nil else {
            throw CLIError("model ID \(id) is reserved for the catalog. Choose a different ID.")
        }
        guard !files.fileExists(atPath: target.path), !files.fileExists(atPath: try path(for: id).path) else {
            throw CLIError("model \(id) is already installed")
        }
        if isMLX { try checkMLX(source) } else { try checkGGUF(source) }
        try stage { staging in
            let copy = staging.appendingPathComponent(isMLX ? "model.mlx" : "model.gguf")
            if isMLX {
                try files.createDirectory(at: copy, withIntermediateDirectories: false)
                for file in try mlxFiles(source) {
                    let relative = mlxRelativePath(file, in: source)
                    let target = copy.appendingPathComponent(relative)
                    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.copyItem(at: file, to: target)
                }
            } else { try files.copyItem(at: source, to: copy) }
            try install(copy, at: target)
        }
    }

    func install(_ source: URL, at target: URL, receipt: LocalModelHuggingFace.Receipt? = nil) throws {
        if source.pathExtension == "mlx" { try checkMLX(source) } else { try checkGGUF(source) }
        if let receipt {
            let bundle = source.deletingLastPathComponent().appendingPathComponent("model.hf", isDirectory: true)
            try files.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try files.moveItem(at: source, to: bundle.appendingPathComponent("model.gguf"))
            let receiptFile = bundle.appendingPathComponent("receipt.json")
            try JSONEncoder().encode(receipt).write(to: receiptFile, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptFile.path)
            try files.createDirectory(at: target.deletingLastPathComponent().deletingLastPathComponent(),
                                      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The receipt and weights become visible together, with no partially installed model.
            try files.moveItem(at: bundle, to: target.deletingLastPathComponent())
            return
        }
        try files.createDirectory(at: weights, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.moveItem(at: source, to: target)
    }

    /// Call after the runner has checked that this model is not active.
    func remove(_ id: String) throws {
        if id.hasPrefix("hf.co/") {
            let target = huggingFacePath(for: try LocalModelHuggingFace.Reference(id))
            try files.removeItem(at: target.deletingLastPathComponent())
            return
        }
        let target = try path(for: id)
        if isExternal(target) { throw CLIError("This model belongs to \(externalSource(id)). Remove it there.") }
        try files.removeItem(at: target)
    }

    func checkGGUF(_ file: URL) throws {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) >= 24 else {
            throw CLIError("expected a GGUF weights file at \(file.path)")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw CLIError("invalid GGUF header at \(file.path)")
        }
    }

    func stage<T>(_ action: (URL) throws -> T) throws -> T {
        // Never create a missing custom folder: an unplugged drive would put the weights on the startup disk.
        if let customWeights, !files.fileExists(atPath: customWeights.path) {
            throw CLIError("the model folder \(customWeights.path) is not available. Connect its drive or change it with 'noodle model location'")
        }
        let staging = scratch.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        return try action(staging)
    }

    func withLock<T>(_ name: String, _ action: () throws -> T) throws -> T {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw modelPOSIXError() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw modelPOSIXError() }
        }
        if name == "operation" {
            // A command killed during a download can leave its staging directory behind.
            for url in (try? files.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [] {
                let name = url.lastPathComponent
                if name.hasPrefix(".stage-"), UUID(uuidString: String(name.dropFirst(".stage-".count))) != nil {
                    try? files.removeItem(at: url)
                }
            }
            removeStalePartials()
        }
        return try action()
    }
}

func modelPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
