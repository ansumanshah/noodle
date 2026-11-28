import Foundation
import NoodleCore

/// Verify the pinned release archive before extraction. The receipt records the
/// executable hash derived from that verified archive for subsequent invocations.
struct ScanTool {
    let name: String
    let version: String
    let archiveSHA256: String

    static let grypeDarwinArm64ArchiveSHA256 = "54336f2cd8cdee8b3d8ea83462561ff7fa9293498054c7c53a193db44bfea4c8"
    static let syftDarwinArm64ArchiveSHA256 = "e0a74a5d2688d1254b4e17b71f068a83215e3625f846265bf6614c7ba06f3a96"
    static let grype = ScanTool(name: "grype", version: "0.121.3",
                               archiveSHA256: grypeDarwinArm64ArchiveSHA256)
    static let syft = ScanTool(name: "syft", version: "1.57.1",
                              archiveSHA256: syftDarwinArm64ArchiveSHA256)

    private struct Receipt: Codable {
        let name: String
        let version: String
        let archiveSHA256: String
        let executableSHA256: String
    }

    private func installedFileOK(in directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("verified.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.name == name, receipt.version == version,
              receipt.archiveSHA256 == archiveSHA256,
              Digest.isValid("sha256:" + receipt.executableSHA256) else { return false }
        return toolFileOK(directory.appendingPathComponent(name), sha: receipt.executableSHA256)
    }

    func executable() throws -> URL {
        guard Digest.isValid("sha256:" + archiveSHA256) else {
            throw CLIError("verified SHA-256 pins are missing for \(name) \(version); no download or execution was attempted")
        }
        let fm = FileManager.default
        let dir = paths.root.appendingPathComponent("tools/scanners/\(name)-\(version)")
        let binary = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dir.path) {
            guard installedFileOK(in: dir) else {
                throw CLIError("Could not verify installed \(name); remove \(dir.path) and retry")
            }
            return binary
        }
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        scanSweepStale(in: dir.deletingLastPathComponent(), prefix: ".download-")
        let work = dir.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("release.tar.gz")
        let file = "\(name)_\(version)_darwin_arm64.tar.gz"
        let url = "https://github.com/anchore/\(name)/releases/download/v\(version)/\(file)"
        // Optional offline release archive. It must satisfy exactly the same
        // compiled-in pin as a download; it cannot override the trusted hash.
        if let local = env["NOODLE_SCAN_TOOL_ARCHIVE"], !local.isEmpty {
            try fm.copyItem(at: URL(fileURLWithPath: local), to: archive)
        } else {
            err("downloading \(name) \(version)")
            let fetched = run("/usr/bin/curl", ["--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "300", "--output", archive.path, url])
            guard fetched.code == 0 else { throw CLIError("cannot download \(name): \(fetched.out)") }
        }
        guard try Digest.sha256(file: archive) == "sha256:" + archiveSHA256 else {
            throw CLIError("SHA-256 mismatch for \(file); download discarded")
        }
        let unpacked = run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path, name])
        guard unpacked.code == 0 else { throw CLIError("cannot unpack \(name): \(unpacked.out)") }
        let staged = work.appendingPathComponent(name)
        guard try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try staged.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CLIError("invalid executable in verified archive for \(name)")
        }
        let executableSHA256 = String(try Digest.sha256(file: staged).dropFirst(7))
        let receipt = Receipt(name: name, version: version, archiveSHA256: archiveSHA256,
                              executableSHA256: executableSHA256)
        try JSONEncoder().encode(receipt).write(to: work.appendingPathComponent("verified.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Atomic publication; concurrent installs may win, but are verified too.
        try fm.removeItem(at: archive)
        do { try fm.moveItem(at: work, to: dir) }
        catch { if !installedFileOK(in: dir) { throw error } }
        guard installedFileOK(in: dir) else { throw CLIError("SHA-256 mismatch for installed \(name)") }
        return binary
    }
}

/// Remove scratch directories left behind by a killed run (older than an hour,
/// so a concurrent scan's live directory is never touched).
func scanSweepStale(in directory: URL, prefix: String) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for item in items where item.lastPathComponent.hasPrefix(prefix) {
        let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        if Date().timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: item) }
    }
}

/// Use an allowlist rather than inheriting Docker/registry/cloud credentials,
/// proxy credentials, scanner configuration, or telemetry settings from the user.
/// Config and HOME are private scratch directories, with persistent caches only.
func scanProcess(_ binary: URL, arguments: [String], work: URL, output: URL) throws -> Int32 {
    let fm = FileManager.default
    let cache = paths.root.appendingPathComponent("cache/scans")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CLIError("cannot create scanner output")
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let config = work.appendingPathComponent("config.yaml")
    try Data("{}\n".utf8).write(to: config)
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments + ["--config", config.path]
    process.currentDirectoryURL = work
    process.environment = [
        "HOME": work.path, "PATH": "/usr/bin:/bin", "TMPDIR": work.path,
        "XDG_CONFIG_HOME": work.path, "XDG_CACHE_HOME": cache.path,
        "GRYPE_DB_CACHE_DIR": cache.appendingPathComponent("grype/db").path,
        "GRYPE_CHECK_FOR_APP_UPDATE": "false", "SYFT_CHECK_FOR_APP_UPDATE": "false",
        "SYFT_CACHE_DIR": cache.appendingPathComponent("syft").path,
        "GRYPE_REGISTRY_AUTH_AUTHORITY": "", "SYFT_REGISTRY_AUTH_AUTHORITY": ""
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
