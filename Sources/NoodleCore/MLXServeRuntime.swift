import Foundation

public struct MLXServeError: LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }
    public init(_ message: String) { description = message }
}

/// The pinned MLX runtime release. The archive is downloaded on first use, verified, extracted whole
/// and run in place, because its bundled libraries load through `@executable_path`.
/// Blocking: call from a worker thread, never a NIO event loop.
public enum MLXServeRuntime {
    public struct Pin: Equatable, Sendable {
        public let version: String
        public let url: String
        public let size: UInt64
        public let sha256: String

        public init(version: String, url: String, size: UInt64, sha256: String) {
            self.version = version
            self.url = url
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let version = "26.11.4"
    public static let pin = Pin(
        version: version,
        url: "https://github.com/ddalcu/mlx-serve/releases/download/v\(version)/mlx-serve-bin-macos-arm64.tar.gz",
        size: 98_362_127,
        sha256: "sha256:2079e8649b4a25aed267bf43117ef23b026c833453f0cdd0eff2d328aa1e0832")

    public static let executableName = "mlx-serve"
    private static let library = "lib/libmlx.dylib"
    private static let stagePrefix = ".install-"
    /// The retired Python virtualenv that earlier builds installed beside the model weights.
    private static let legacyRuntime = "mlx-runtime"

    private static func root(_ models: URL) -> URL { models.appendingPathComponent("mlx-serve", isDirectory: true) }

    public static func installation(in models: URL, pin: Pin = MLXServeRuntime.pin) -> URL {
        root(models).appendingPathComponent(pin.version, isDirectory: true)
    }

    /// The installed executable, or nil until `install` has moved a complete copy into place.
    public static func executable(in models: URL, pin: Pin = MLXServeRuntime.pin) -> URL? {
        let dir = installation(in: models, pin: pin)
        let binary = dir.appendingPathComponent(executableName)
        let files = FileManager.default
        guard files.isExecutableFile(atPath: binary.path), files.fileExists(atPath: dir.appendingPathComponent(library).path) else { return nil }
        return binary
    }

    public static func downloadFailure(_ pin: Pin, _ reason: String) -> MLXServeError {
        MLXServeError("Cannot download MLX support from \(pin.url): \(reason). Check the connection and try again.")
    }

    public static func verify(_ archive: URL, pin: Pin = MLXServeRuntime.pin) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value
        guard size == pin.size else { throw MLXServeError("MLX support size mismatch; expected \(pin.size) bytes") }
        guard try Digest.sha256(file: archive) == pin.sha256 else { throw MLXServeError("MLX support SHA-256 mismatch") }
    }

    /// Verifies `archive` before reading any of it, extracts into a sibling staging folder and renames the
    /// whole tree into place, so a failed or interrupted install never leaves a half-written version folder.
    @discardableResult
    public static func install(archive: URL, into models: URL, pin: Pin = MLXServeRuntime.pin) throws -> URL {
        try verify(archive, pin: pin)
        let files = FileManager.default
        let parent = root(models)
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeStale(in: parent)
        let stage = parent.appendingPathComponent(stagePrefix + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }
        let unpacked = stage.appendingPathComponent("unpacked", isDirectory: true)
        try files.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try untar(archive, into: unpacked)
        let tree = try contents(of: unpacked)
        guard files.isExecutableFile(atPath: tree.appendingPathComponent(executableName).path),
              files.fileExists(atPath: tree.appendingPathComponent(library).path) else {
            throw MLXServeError("MLX support archive is missing \(executableName) or its libraries")
        }
        let target = installation(in: models, pin: pin)
        try? files.removeItem(at: target)
        try files.moveItem(at: tree, to: target)
        removeSuperseded(in: models, keeping: pin)
        return target.appendingPathComponent(executableName)
    }

    /// Remove older pinned versions and the retired Python runtime after the new tree is installed.
    public static func removeSuperseded(in models: URL, keeping pin: Pin = MLXServeRuntime.pin) {
        let files = FileManager.default
        let keep = pin.version
        for url in (try? files.contentsOfDirectory(at: root(models), includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent != keep && !url.lastPathComponent.hasPrefix(stagePrefix) {
            try? files.removeItem(at: url)
        }
        try? files.removeItem(at: models.appendingPathComponent(legacyRuntime, isDirectory: true))
        for url in (try? files.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("llama.cpp-") { try? files.removeItem(at: url) }
    }

    private static func removeStale(in parent: URL) {
        let files = FileManager.default
        for url in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(stagePrefix) { try? files.removeItem(at: url) }
    }

    /// The release tarball wraps everything in one folder; a flat one is accepted too.
    private static func contents(of unpacked: URL) throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: unpacked.appendingPathComponent(executableName).path) { return unpacked }
        let entries = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey])
        guard entries.count == 1, (try entries[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw MLXServeError("MLX support archive has an unexpected layout")
        }
        return entries[0]
    }

    private static func untar(_ archive: URL, into folder: URL) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", folder.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MLXServeError("cannot unpack MLX support. \(String(decoding: output.prefix(2048), as: UTF8.self))")
        }
    }
}
