import Foundation

/// Lazy Docker plugins have no resident process. Their metadata never needs a download.
public enum LazyToolPlugin {
    /// Model needs Noodle's environment preparation on every invocation, including cached tools.
    public static func retainsStub(_ name: String) -> Bool { name == Tools.modelPlugin }

    public static func metadata(_ name: String) -> String? {
        guard let pin = Tools.pins.first(where: { $0.name == name }), pin.kind == .plugin else { return nil }
        let version = pin.version
        let description: String
        switch name {
        case "docker-compose": description = "Docker Compose"
        case "docker-buildx": description = "Docker Buildx"
        default: description = "Docker Model Runner"
        }
        return "{\"SchemaVersion\":\"0.1.0\",\"Vendor\":\"Docker Inc.\",\"Version\":\"v\(version)\",\"ShortDescription\":\"\(description)\"}"
    }

    public static func directory(_ paths: NoodlePaths) -> URL {
        Tools.directory(paths).appendingPathComponent("lazy-plugins", isDirectory: true)
    }

    private static func header(_ name: String) -> String { "#!/bin/sh\n# Noodle lazy Docker plugin: \(name)\n" }

    public static func script(_ name: String, cli: URL, paths: NoodlePaths) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return header(name) + "exec \(quote(cli.path)) __tool-plugin \(quote(name)) \(quote(paths.root.path)) \"$0\" \"$@\"\n"
    }

    /// Bounded read, including through the Docker config link. Discovery must not execute a stub.
    public static func isStub(_ url: URL, name: String) -> Bool {
        guard metadata(name) != nil, FileManager.default.isExecutableFile(atPath: url.path),
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 4096) else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix(header(name))
    }

    public static func owns(_ link: URL, receipt: [String: String]) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              let recorded = receipt["link:" + link.path] else { return false }
        return target == recorded || target == receipt["pending-link:" + link.path]
    }

    public static func ownsStub(_ link: URL, name: String, paths: NoodlePaths, receipt: [String: String]) -> Bool {
        owns(link, receipt: receipt) && (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            == directory(paths).appendingPathComponent(name).path
    }

    /// Only a complete script pointing at the currently retained, unchanged CLI is ready.
    public static func ready(_ link: URL, name: String, paths: NoodlePaths, home: String, receipt: [String: String]) -> Bool {
        guard ownsStub(link, name: name, paths: paths, receipt: receipt) else { return false }
        let candidates = [(URL(fileURLWithPath: home).appendingPathComponent(".local/bin/noodle"), "cli-sha256"),
                          (paths.root.appendingPathComponent("bin/noodle"), "fallback-cli-sha256")]
        guard let cli = candidates.first(where: { file, key in
            FileManager.default.isExecutableFile(atPath: file.path) && receipt[key] != nil
                && (try? Digest.sha256(file: file)) == receipt[key]
        })?.0 else { return false }
        return FileManager.default.isExecutableFile(atPath: link.path)
            && (try? Data(contentsOf: link)) == Data(script(name, cli: cli, paths: paths).utf8)
    }

    /// Persist both possible targets before rename. A failed final receipt write still owns the link.
    public static func replaceOwned(_ link: URL, with target: URL, receipt: [String: String],
                                    record: (String, String) throws -> Void) throws {
        guard owns(link, receipt: receipt) else { throw POSIXError(.EPERM) }
        try record("pending-link:" + link.path, target.path)
        try replace(link, with: target)
        try record("link:" + link.path, target.path)
    }

    /// Stage beside the link so readers always see either the stub or the complete upstream tool.
    public static func replace(_ link: URL, with target: URL) throws {
        let fm = FileManager.default
        let staged = link.deletingLastPathComponent().appendingPathComponent(".noodle-plugin-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.createSymbolicLink(at: staged, withDestinationURL: target)
        guard rename(staged.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// The same process-scoped advisory lock used by the BuildKit installer. Never use on a NIO loop.
public final class ToolInstallLock {
    private let descriptor: Int32

    /// Kept outside NOODLE_HOME, including across tools remove and uninstall --delete-data.
    public static func file(_ paths: NoodlePaths) -> URL {
        let root = paths.root.standardizedFileURL.resolvingSymlinksInPath()
        let hash = Digest.sha256(Data(root.path.utf8)).dropFirst(7)
        return root.deletingLastPathComponent().appendingPathComponent(".noodle-tools-\(hash).lock")
    }

    public init(paths: NoodlePaths) throws {
        let file = Self.file(paths)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
