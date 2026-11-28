import Foundation

/// Filesystem layout. Root defaults to `~/.noodle`, overridable with `NOODLE_HOME`.
public struct NoodlePaths: Sendable, Equatable {
    public let root: URL

    private let resources: URL?
    /// Bundled tools and boot files (the app's Resources, or `NOODLE_RESOURCES`).
    public var resourcesDirectory: URL? { resources }

    public init(root: URL, resources: URL? = nil) {
        self.root = root
        self.resources = resources
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executableURL: URL? = Bundle.main.executableURL) -> NoodlePaths {
        let root = environment["NOODLE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".noodle", isDirectory: true)
        let resources = environment["NOODLE_RESOURCES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        return NoodlePaths(root: root, resources: resources)
    }

    public var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    /// Docker API socket. Unix socket paths are capped near 104 bytes; callers should check `socketPathFits`.
    public var socket: URL { runDir.appendingPathComponent("docker.sock") }
    public var socketPathFits: Bool { socket.path.utf8.count < 100 }
    /// The same API for guest containers that bind the Docker socket; `/noodle/*` is refused there.
    public var guestSocket: URL { runDir.appendingPathComponent("guest.sock") }
    public var bootDir: URL { root.appendingPathComponent("boot", isDirectory: true) }
    public var kernel: URL { bootFile("vmlinux") }
    public var initramfs: URL { bootFile("initramfs.cpio.gz") }
    private func bootFile(_ name: String) -> URL {
        let local = bootDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let bundled = resources?.appendingPathComponent(name), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return local
    }
    public var dataDisk: URL { root.appendingPathComponent("data.img") }
    public var vmLog: URL { root.appendingPathComponent("vm.log") }
    /// The workload VM (privileged and unconfined containers) keeps its disk and log apart from the main VM's.
    public var workloadDir: URL { root.appendingPathComponent("privileged", isDirectory: true) }
    public var workloadDisk: URL { workloadDir.appendingPathComponent("data.img") }
    public var workloadVMLog: URL { workloadDir.appendingPathComponent("vm.log") }
    public var settingsFile: URL { root.appendingPathComponent("vm.json") }
    public var blobsDir: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var imagesFile: URL { root.appendingPathComponent("images.json") }
    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var hostNamesFile: URL { root.appendingPathComponent("host-names.json") }
    public var proxyFile: URL { root.appendingPathComponent("proxy.json") }
    public var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    public func blobPath(digest: String) -> URL {
        // An invalid digest resolves to a path that never exists, never outside blobs/.
        guard Digest.isValid(digest) else { return blobsDir.appendingPathComponent("invalid", isDirectory: true).appendingPathComponent("none") }
        let (algo, hex) = Digest.split(digest)
        return blobsDir.appendingPathComponent(algo, isDirectory: true).appendingPathComponent(hex)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        let previous = root.appendingPathComponent("workload", isDirectory: true)
        if fm.fileExists(atPath: previous.path) {
            guard !fm.fileExists(atPath: workloadDir.path) else {
                throw NSError(domain: "NoodlePaths", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Both \(previous.path) and \(workloadDir.path) exist. Move one aside before starting Noodle; neither folder was changed."])
            }
            try fm.moveItem(at: previous, to: workloadDir)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Tighten a root we own; a root owned by someone else is left alone.
        var st = stat()
        if stat(root.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 != 0 {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        for dir in [runDir, bootDir, blobsDir, tmpDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
