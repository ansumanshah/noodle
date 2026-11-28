import Foundation
import Darwin
import NoodleCore

public enum ImageError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case digestMismatch(expected: String, actual: String)
    case registry(status: Int, message: String)
    case unauthorized(String)
    case noMatchingPlatform(String)
    case invalid(String)
    case conflict(String)
    case io(String)

    public var description: String {
        switch self {
        case .notFound(let s): return "No such image: \(s)"
        case .digestMismatch(let e, let a): return "digest mismatch: expected \(e), got \(a)"
        case .registry(let st, let m): return "registry error \(st): \(m)"
        case .unauthorized(let m): return "unauthorized: \(m)"
        case .noMatchingPlatform(let s): return "no matching manifest for \(s)"
        case .invalid(let s): return s
        case .conflict(let s): return s
        case .io(let s): return s
        }
    }
}

/// Content-addressed blob files under `root/blobs/<algo>/<hex>`. Writes go to `root/tmp` first and are renamed in
/// after the digest verifies, so a crash never leaves a bad blob under its final name.
public final class BlobStore: Sendable {
    public let paths: NoodlePaths
    public init(paths: NoodlePaths) {
        self.paths = paths
        try? FileManager.default.createDirectory(at: paths.blobsDir.appendingPathComponent("sha256"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.tmpDir, withIntermediateDirectories: true)
    }

    public func url(_ digest: String) -> URL { paths.blobPath(digest: digest) }
    public func has(_ digest: String) -> Bool { Digest.isValid(digest) && FileManager.default.fileExists(atPath: url(digest).path) }
    public func size(_ digest: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url(digest).path)[.size] as? NSNumber)?.int64Value
    }

    public func tempURL() -> URL {
        paths.tmpDir.appendingPathComponent("blob-" + UUID().uuidString)
    }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        let digest = Digest.sha256(data)
        if has(digest) { return digest }
        let tmp = tempURL()
        try data.write(to: tmp)
        try install(tmp, as: digest)
        return digest
    }

    /// Largest config, manifest or index JSON read into memory.
    public static let metadataLimit: Int64 = 16 << 20

    /// Read a metadata blob (config JSON), refusing one larger than `metadataLimit` before reading it.
    public func read(_ digest: String) throws -> Data {
        guard Digest.isValid(digest) else { throw ImageError.invalid("bad digest \(digest)") }
        guard FileManager.default.fileExists(atPath: url(digest).path) else { throw ImageError.notFound(digest) }
        return try Self.readMetadata(url(digest))
    }

    /// Read a small JSON file, checking its size first.
    public static func readMetadata(_ file: URL) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= metadataLimit else { throw ImageError.invalid("metadata file is larger than \(metadataLimit >> 20) MiB") }
        do { return try Data(contentsOf: file) } catch { throw ImageError.notFound(file.lastPathComponent) }
    }

    /// Verify `file` hashes to `expected` (when given) and move it into the store. Returns the digest.
    @discardableResult
    public func adopt(file: URL, expected: String? = nil) throws -> String {
        let actual = try Digest.sha256(file: file)
        if let expected, expected != actual {
            try? FileManager.default.removeItem(at: file)
            throw ImageError.digestMismatch(expected: expected, actual: actual)
        }
        try install(file, as: actual)
        return actual
    }

    /// Move a file whose digest is already verified.
    public func install(_ file: URL, as digest: String) throws {
        let dest = url(digest)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: file); return }
        try ImageDurability.sync(file)
        do { try fm.moveItem(at: file, to: dest) } catch { throw ImageError.io("store blob: \(error)") }
        try ImageDurability.sync(dest.deletingLastPathComponent())
    }

    public func remove(_ digest: String) {
        try? FileManager.default.removeItem(at: url(digest))
    }

    public func all() -> [(digest: String, size: Int64)] {
        let dir = paths.blobsDir.appendingPathComponent("sha256")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { n in
            let d = "sha256:" + n
            return size(d).map { (d, $0) }
        }
    }

    public func clearTemp() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: paths.tmpDir.path) {
            for n in names { try? FileManager.default.removeItem(at: paths.tmpDir.appendingPathComponent(n)) }
        }
    }
}


public enum ImageDurability {
    /// Temp file, fsync, rename, fsync the directory: a crash leaves the old file or the new one, never a torn one.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent("." + url.lastPathComponent + "-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        try sync(temp)
        try rename(temp, to: url)
        try sync(dir)
    }

    static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ImageError.io("open for sync \(url.path): \(String(cString: strerror(errno)))") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw ImageError.io("sync \(url.path): \(String(cString: strerror(errno)))") }
    }

    static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw ImageError.io("rename \(destination.path): \(String(cString: strerror(errno)))")
        }
    }
}
