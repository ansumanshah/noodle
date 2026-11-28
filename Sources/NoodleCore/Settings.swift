import Foundation

public struct SettingsFileError: Error, CustomStringConvertible, Sendable {
    public let path: String
    public let reason: String
    public var description: String {
        "\(path) is not valid Noodle settings, so Noodle will not start (it could hold \"host_loopback\": false). Fix or remove the file. \(reason)"
    }
}

/// VM sizing. `vm.json` keys: `cpus`, `memory_mib`. Env `NOODLE_CPUS` / `NOODLE_MEMORY_MIB` override the file.
public struct VMSettings: Codable, Sendable, Equatable {
    public var cpus: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    public var idleSleepSeconds: Int
    public var approvedDirectories: [String]
    /// Containers reach Mac loopback services through `host.docker.internal`. `host_loopback: false` turns
    /// the relay off from the next daemon start: no vsock 1034 listener and no guest redirect.
    public var hostLoopback: Bool
    /// "Let Kubernetes use your shared folders": the workload VM gets the Mac sharing device and privileged containers
    /// (the k3s node included) may bind approved folders only. nil until `noodle kubernetes start` first
    /// decides it; nil and false both mean off. Applies when the workload VM boots.
    public var workloadSharedFolders: Bool?
    /// Mac address for a published port that names none (`-p 8080:80`, `-P`). nil keeps Docker's default, every
    /// interface. `"publish_address": "127.0.0.1"` keeps such ports off the network; `-p 0.0.0.0:8080:80` still opens one.
    public var publishAddress: String?

    enum CodingKeys: String, CodingKey {
        case cpus
        case memoryMiB = "memory_mib"
        case diskGiB = "disk_gib"
        case idleSleepSeconds = "idle_sleep_seconds"
        case approvedDirectories = "approved_directories"
        case hostLoopback = "host_loopback"
        case workloadSharedFolders = "kubernetes_shared_folders"
        case publishAddress = "publish_address"
    }

    public static func defaults() -> VMSettings {
        let host = ProcessInfo.processInfo
        let cpus = max(2, min(host.activeProcessorCount / 2, 8))
        // Quarter of host RAM, between 1 and 4 GiB. The balloon hands the rest back.
        let quarter = Int(host.physicalMemory / 4 / 1_048_576)
        return VMSettings(cpus: cpus, memoryMiB: max(1024, min(quarter, 4096)), diskGiB: 64, idleSleepSeconds: 60)
    }

    public init(cpus: Int, memoryMiB: Int, diskGiB: Int = 64, idleSleepSeconds: Int = 60, approvedDirectories: [String] = [],
                hostLoopback: Bool = true) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        self.idleSleepSeconds = idleSleepSeconds
        self.approvedDirectories = approvedDirectories
        self.hostLoopback = hostLoopback
    }

    public init(from decoder: Decoder) throws {
        let d = VMSettings.defaults()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus
        memoryMiB = try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? d.memoryMiB
        diskGiB = try c.decodeIfPresent(Int.self, forKey: .diskGiB) ?? d.diskGiB
        idleSleepSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSleepSeconds) ?? d.idleSleepSeconds
        approvedDirectories = try c.decodeIfPresent([String].self, forKey: .approvedDirectories) ?? []
        hostLoopback = try c.decodeIfPresent(Bool.self, forKey: .hostLoopback) ?? true
        workloadSharedFolders = try c.decodeIfPresent(Bool.self, forKey: .workloadSharedFolders)
        publishAddress = try c.decodeIfPresent(String.self, forKey: .publishAddress)
        // A typo must not fall back to every interface: the file is refused and noodled does not start.
        if let publishAddress {
            var parsed = in6_addr()
            guard inet_pton(AF_INET, publishAddress, &parsed) == 1 || inet_pton(AF_INET6, publishAddress, &parsed) == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .publishAddress, in: c, debugDescription: "publish_address must be an IP address such as 127.0.0.1")
            }
        }
    }

    /// The host address to bind for a publication that asked for `requested`; an empty request takes the setting.
    public func publishIP(_ requested: String) -> String { requested.isEmpty ? publishAddress ?? "" : requested }

    public static func canonicalDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return canonical
    }

    public func approvesFile(_ path: String) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return approvedDirectories.contains { root in
            guard (try? Self.canonicalDirectory(root)) == root else { return false }
            return root == "/" || parent == root || parent.hasPrefix(root + "/")
        }
    }

    /// A path the user approved: an approved folder itself or anything below it.
    public func approvesPath(_ path: String) -> Bool {
        approvedDirectories.contains { root in
            guard (try? Self.canonicalDirectory(root)) == root else { return false }
            return root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }

    /// Approved folders the k3s node bind-mounts at the same path. Folders that moved or no longer exist are skipped.
    // shortcut: a path with ':' cannot be spelled in `-v`, so it is skipped; upgrade when the node is created with --mount.
    public var kubernetesNodeFolders: [String] {
        approvedDirectories.filter { (try? Self.canonicalDirectory($0)) == $0 && !$0.contains(":") }
    }

    /// Why a privileged container may not bind `path` from the Mac, or nil when it may: the setting is on and the
    /// path sits inside an approved folder. Directory binds in the main VM need no approval; here every bind does.
    public func workloadBindRefusal(_ path: String) -> String? {
        guard workloadSharedFolders == true else {
            return "privileged and unconfined containers run in a separate VM that shares no Mac folders, so bind mount \(path) is not available. To let it use your approved folders, run: noodle kubernetes shared-folders on"
        }
        // `..`, a symlink or a trailing slash could step out of the approved folder: only the canonical spelling binds.
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == path else {
            return "privileged and unconfined containers can bind only canonical paths, and \(path) has `..`, a symlink or a trailing slash. Use the real path of the folder"
        }
        guard approvesPath(path) else {
            return "privileged and unconfined containers can bind only approved folders, and \(path) is not in one. To allow it, run: noodle share add <folder>"
        }
        return nil
    }

    public static func load(paths: NoodlePaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> VMSettings {
        var s = defaults()
        if let data = try? Data(contentsOf: paths.settingsFile) {
            if let decoded = try? JSONDecoder().decode(VMSettings.self, from: data) { s = decoded }
            // A file that does not decode may hold `"host_loopback": false`: fail closed. noodled refuses
            // to start on it at all (`validateFile`).
            else { s.hostLoopback = false }
        }
        if let v = environment["NOODLE_CPUS"].flatMap({ Int($0) }), v > 0 { s.cpus = v }
        if let v = environment["NOODLE_MEMORY_MIB"].flatMap({ Int($0) }), v >= 256 { s.memoryMiB = v }
        s.cpus = max(1, s.cpus)
        s.memoryMiB = max(256, s.memoryMiB)
        s.diskGiB = max(1, s.diskGiB)
        s.idleSleepSeconds = max(5, s.idleSleepSeconds)
        return s
    }

    /// Throws with the file path and the decoder's reason when `vm.json` exists but is not valid settings.
    public static func validateFile(paths: NoodlePaths) throws {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return }
        do { _ = try JSONDecoder().decode(VMSettings.self, from: data) } catch {
            throw SettingsFileError(path: paths.settingsFile.path, reason: "\(error)")
        }
    }

    /// Keep what other tools change in the file while a form is open: approved folders and the loopback switch.
    public func keepingFileManagedValues(from disk: VMSettings) -> VMSettings {
        var s = self
        s.approvedDirectories = disk.approvedDirectories
        s.hostLoopback = disk.hostLoopback
        s.workloadSharedFolders = disk.workloadSharedFolders
        s.publishAddress = disk.publishAddress
        return s
    }

    public func save(paths: NoodlePaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}
