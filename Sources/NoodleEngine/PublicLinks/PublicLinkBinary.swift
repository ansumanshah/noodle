import Foundation
import NoodleCore

// SHA-256 of the cloudflared GitHub release asset for this version.
private let cloudflaredPinnedVersion = "2026.11.0"
private let cloudflaredDarwinARM64ArchiveSHA256 = "8c2f90277ef06a6080bb40b964d33f09f1188102f8798f2e344174b6cf41accf"

extension PublicLinkManager {
    static func binary(paths: NoodlePaths) throws -> (path: String, sha256: String) {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["NOODLE_CLOUDFLARED"] {
            guard override.hasPrefix("/"), let sha = environment["NOODLE_CLOUDFLARED_SHA256"], Digest.isValid("sha256:" + sha),
                  FileManager.default.isExecutableFile(atPath: override),
                  try Digest.sha256(file: URL(fileURLWithPath: override)) == "sha256:" + sha else {
                throw EngineError.invalid("cloudflared SHA-256 mismatch or missing NOODLE_CLOUDFLARED_SHA256")
            }
            return (override, "sha256:" + sha)
        }
        let fm = FileManager.default
        let tools = paths.root.appendingPathComponent("tools")
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        // Serialise first-use installs across concurrent CLI requests, without a timer or blocking a NIO loop.
        let lockFD = open(tools.appendingPathComponent(".cloudflared.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw EngineError.internalError("cannot lock cloudflared installation") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw EngineError.internalError("cannot lock cloudflared installation") }
        let final = tools.appendingPathComponent("cloudflared-" + cloudflaredPinnedVersion)
        let marker = final.appendingPathExtension("sha256")
        if fm.fileExists(atPath: final.path) || fm.fileExists(atPath: marker.path) {
            guard let digest = try? String(contentsOf: marker, encoding: .utf8), Digest.isValid(digest),
                  fm.isExecutableFile(atPath: final.path), (try? Digest.sha256(file: final)) == digest else {
                throw EngineError.invalid("installed cloudflared SHA-256 mismatch or missing executable hash; remove \(final.path) and \(marker.path) before trying again")
            }
            return (final.path, digest)
        }
        // Test seam for the download path: a local archive and its expected digest replace the pinned URL and digest together.
        let archiveOverride = environment["NOODLE_CLOUDFLARED_ARCHIVE"], digestOverride = environment["NOODLE_CLOUDFLARED_ARCHIVE_SHA256"]
        let work = tools.appendingPathComponent(".cloudflared-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("cloudflared.tgz")
        let url = "https://github.com/cloudflare/cloudflared/releases/download/\(cloudflaredPinnedVersion)/cloudflared-darwin-arm64.tgz"
        if let archiveOverride {
            guard archiveOverride.hasPrefix("/"), digestOverride != nil else { throw EngineError.invalid("NOODLE_CLOUDFLARED_ARCHIVE needs an absolute path and NOODLE_CLOUDFLARED_ARCHIVE_SHA256") }
            try fm.copyItem(atPath: archiveOverride, toPath: archive.path)
        } else {
        try command("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "120", "--output", archive.path, url])
        }
        guard try Digest.sha256(file: archive) == "sha256:" + (digestOverride ?? cloudflaredDarwinARM64ArchiveSHA256) else { throw EngineError.invalid("cloudflared archive SHA-256 mismatch; discarded") }
        try command("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path, "cloudflared"])
        let staged = work.appendingPathComponent("cloudflared")
        let digest = try Digest.sha256(file: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staged, to: final)
        try Data(digest.utf8).write(to: marker, options: .atomic)
        return (final.path, digest)
    }

    private static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EngineError.unavailable("cloudflared download or extraction failed") }
    }
}
