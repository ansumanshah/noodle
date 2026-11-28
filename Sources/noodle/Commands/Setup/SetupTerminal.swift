import Foundation
import NoodleCore

private let setupPathStart = "# >>> Noodle PATH >>>"
private let setupPathEnd = "# <<< Noodle PATH <<<"

private func setupExecutable() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buffer, &size)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
}

@discardableResult
func setupTerminal(docker: String?, addPath: Bool) throws -> URL {
    try setupFM.createDirectory(at: setupBin, withIntermediateDirectories: true)
    let executable = setupExecutable()
    var destination = setupBin.appendingPathComponent("noodle")
    let receipt = setupReceipt()
    var occupied = ((try? setupFM.contentsOfDirectory(atPath: setupBin.path)) ?? []).contains("noodle")
    var owned = (try? Digest.sha256(file: destination)) == receipt["cli-sha256"] && receipt["cli-sha256"] != nil
    if occupied && !owned && executable.path != destination.path {
        out("Kept existing \(destination.path)")
        destination = paths.root.appendingPathComponent("bin/noodle")
        try setupFM.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        occupied = setupFM.fileExists(atPath: destination.path)
        owned = (try? Digest.sha256(file: destination)) == receipt["fallback-cli-sha256"] && receipt["fallback-cli-sha256"] != nil
    }
    if executable.path != destination.path {
        if occupied && !owned { throw CLIError("cannot retain the CLI at \(destination.path); existing file preserved") }
        else {
            // Stage next to the destination so replacement stays on one filesystem.
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".noodle-\(getpid())")
            defer { try? setupFM.removeItem(at: staged) }
            try setupFM.copyItem(at: executable, to: staged)
            try setupFM.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            let hash = try Digest.sha256(file: staged)
            guard rename(staged.path, destination.path) == 0 else {
                throw CLIError("cannot replace \(destination.path): \(String(cString: strerror(errno)))")
            }
            try setupRecord(destination.deletingLastPathComponent().standardizedFileURL.path == setupBin.standardizedFileURL.path ? "cli-sha256" : "fallback-cli-sha256", hash)
        }
    }
    try setupRecord(destination.deletingLastPathComponent().standardizedFileURL.path == setupBin.standardizedFileURL.path
                    ? "cli-sha256" : "fallback-cli-sha256", try Digest.sha256(file: destination))
    if let docker {
        let link = setupBin.appendingPathComponent("docker")
        let exists = ((try? setupFM.contentsOfDirectory(atPath: setupBin.path)) ?? []).contains("docker")
        if !exists && docker != link.path {
            try setupFM.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: docker))
            do { try setupRecordLink(link, target: docker) }
            catch { try? setupFM.removeItem(at: link); throw error }
        }
    }
    let line = "export PATH=\"$HOME/.local/bin:$PATH\""
    let onPath = (env["PATH"] ?? "").split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == setupBin.path }
    if !onPath { out("Add this line to your shell profile:\n\(line)") }
    if addPath {
        let shell = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh").lastPathComponent
        guard ["zsh", "bash"].contains(shell) else { throw CLIError("--path supports zsh and bash; add the printed PATH line to your shell configuration") }
        let directory = URL(fileURLWithPath: home)
        let existing = Set(try setupFM.contentsOfDirectory(atPath: directory.path))
        guard let name = SetupPlan.profileName(shell: shell, existing: existing) else { return destination }
        let profile = directory.appendingPathComponent(name)
        let created = !setupFM.fileExists(atPath: profile.path)
        let block = "\n\(setupPathStart)\n\(line)\n\(setupPathEnd)\n"
        if try setupAppendPathBlock(block, to: profile) {
            try setupRecord("profile:" + profile.path, block)
            if created { try setupRecord("created-profile:" + profile.path, "1") }
        }
        out("PATH profile: \(profile.path). Open a new login shell to use it.")
    }
    out("CLI retained for removal after app deletion: \(destination.path) uninstall")
    return destination
}

/// Append the PATH block unless the profile already has one. Writes through a symlinked profile (dotfile managers)
/// instead of replacing the link, and keeps the file's mode, like uninstall does.
func setupAppendPathBlock(_ block: String, to profile: URL) throws -> Bool {
    let target = profile.resolvingSymlinksInPath()
    let exists = setupFM.fileExists(atPath: target.path)
    let original = exists ? try String(contentsOf: target, encoding: .utf8) : ""
    guard !original.contains(setupPathStart) else { return false }
    let mode = exists ? try setupFM.attributesOfItem(atPath: target.path)[.posixPermissions] : nil
    try (original + block).write(to: target, atomically: true, encoding: .utf8)
    if let mode { try setupFM.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
    return true
}
