import Foundation

/// Why first-run setup could not finish, in words a developer can act on.
public enum SetupProblem: Sendable, Equatable {
    case noNetwork, diskFull, brokenDownload, dockerMissing, brokenTool(String), unsupportedShell
    case contextConflict, permission, declined, cliMissing, timedOut, daemonDown, pathNotApplied
    case containerFailed(String), unknown(String)
    /// A docker file in ~/.local/bin that does not run, ahead of the one that works. The path is shown as given.
    case pathBlocked(String)
    /// The import ran and did not finish. The text is the reason in the CLI's words.
    case importFailed(String)
    /// The person stopped a step. The text says what that left behind.
    case stopped(String)

    public var title: String {
        switch self {
        case .noNetwork: "Can’t reach the internet"
        case .diskFull: "Your disk is full"
        case .brokenDownload: "The download didn’t check out"
        case .dockerMissing: "Docker isn’t installed yet"
        case .brokenTool(let name): "\(name) doesn’t run"
        case .unsupportedShell: "Noodle can’t edit your shell profile"
        case .contextConflict: "Another “noodle” Docker context is in the way"
        case .permission: "macOS blocked a change"
        case .declined: "Noodle needs a Docker command"
        case .cliMissing: "The Noodle command line tool is missing"
        case .timedOut: "Setup took too long"
        case .daemonDown: "Noodle didn’t start"
        case .pathNotApplied: "New Terminal windows still won’t find docker"
        case .containerFailed: "The test container didn’t run"
        case .unknown: "Setup couldn’t finish"
        case .pathBlocked(let path): "\(path) doesn’t run"
        case .importFailed: "The import didn’t finish"
        case .stopped: "You stopped setup"
        }
    }

    /// What to do next, in one line. Docker's own words stand in for causes the CLI reported.
    public var advice: String {
        switch self {
        case .noNetwork: "Check your connection, then try again."
        case .diskFull: "Free some disk space, then try again."
        case .brokenDownload: "The bad file was thrown away and nothing from this download was installed. Earlier setup changes remain. Try again."
        case .dockerMissing, .declined: "Allow the download, or install docker yourself, then try again."
        case .brokenTool: "Reinstall it, or let Noodle download its own."
        case .unsupportedShell: "Turn off the Terminal step and add the PATH line yourself."
        case .contextConflict: "Rename or remove that context in Docker, then try again."
        case .permission: "Make your home folder writable by you, then try again."
        case .cliMissing: "Reinstall Noodle from the disk image."
        case .timedOut: "Try again. The connection may be slow."
        case .daemonDown: "Start Noodle from its menu, or try again."
        case .pathNotApplied: "Add the PATH line to your shell profile yourself."
        case .containerFailed(let detail), .unknown(let detail): detail.isEmpty ? "Try again." : detail
        case .pathBlocked: "Noodle left it as it was. Move it aside, then try again."
        case .importFailed(let detail):
            (detail.isEmpty ? "Try again, or skip it." : detail) + " Nothing was removed from your other engine."
        case .stopped(let remains): remains
        }
    }

    // MARK: classify

    /// Maps a failed run (non-zero exit) to a problem by what the tools printed.
    public static func classify(code: Int32, output: String) -> SetupProblem {
        let text = output.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if code == 127 || has("command line tool was not found") { return .cliMissing }
        if code == 124 || has("timed out") { return .timedOut }
        if has("no space left", "enospc", "disk full", "not enough space") { return .diskFull }
        if has("sha-256 mismatch") { return .brokenDownload }
        if has("could not resolve host", "curl: (6)", "curl: (7)", "curl: (28)", "curl: (35)", "network is unreachable",
               "no such host", "i/o timeout", "no route to host", "internet connection appears to be offline",
               "tls handshake timeout", "connection refused", "dial tcp") && !has("docker.sock") { return .noNetwork }
        if has("docker cli unavailable") { return .dockerMissing }
        if has("supports zsh and bash") { return .unsupportedShell }
        if has("belongs to another installation", "metadata is unreadable") { return .contextConflict }
        if has("permission denied", "operation not permitted", "read-only file system") { return .permission }
        if has("cannot unpack", "exec format error", "bad cpu type") { return .brokenTool("docker") }
        if has("cannot connect to the docker daemon", "is the docker daemon running") { return .daemonDown }
        return .unknown(lastLine(output))
    }

    /// The last meaningful line, without the CLI's "noodle:" prefix.
    public static func lastLine(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return line.hasPrefix("noodle: ") ? String(line.dropFirst(8)) : line
    }
}

/// What was observed after `noodle setup` returned. Exit 0 alone is never trusted.
public struct SetupFacts: Sendable, Equatable {
    public var dockerPath: String?
    public var daemonUp: Bool
    public var dockerReachesNoodle: Bool     // `docker --host <socket> version` succeeded
    public var pathApplied: Bool?            // nil when the Terminal step was not requested
    /// A docker file in ~/.local/bin that fails when run, so a new Terminal would pick it first.
    public var pathConflict: String?
    public init(dockerPath: String?, daemonUp: Bool, dockerReachesNoodle: Bool, pathApplied: Bool? = nil, pathConflict: String? = nil) {
        self.dockerPath = dockerPath; self.daemonUp = daemonUp
        self.dockerReachesNoodle = dockerReachesNoodle; self.pathApplied = pathApplied; self.pathConflict = pathConflict
    }
}

public enum SetupVerdict {
    /// Nil only when `docker` really works against Noodle. Missing Compose or Buildx is not a failure.
    public static func evaluate(code: Int32, output: String, facts: SetupFacts) -> SetupProblem? {
        if code != 0 { return .classify(code: code, output: output) }
        if facts.dockerPath == nil { return .dockerMissing }
        if !facts.daemonUp { return .daemonDown }
        if !facts.dockerReachesNoodle { return .brokenTool("The Docker command") }
        if let path = facts.pathConflict { return .pathBlocked(path) }
        if facts.pathApplied == false { return .pathNotApplied }
        return nil
    }

    /// Nil only when the import finished with nothing failed. Exit 0 with failed items still counts as a failure.
    public static func importResult(code: Int32, output: String) -> SetupProblem? {
        let outcome = ImportOutcome.parse(output)
        if code == 0, let outcome, outcome.failed == 0 { return nil }
        if code == 0, outcome == nil { return .importFailed("The import did not report a result. Try again, or skip it.") }
        if code == 124 { return .importFailed("It took too long.") }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let reason = lines.last { $0.contains("FAILED") } ?? SetupProblem.lastLine(output)
        guard let failed = outcome?.failed, failed > 0 else { return .importFailed(reason) }
        return .importFailed("\(failed) \(failed == 1 ? "item" : "items") didn’t copy. \(reason)")
    }

    /// Tools the CLI said it could not provide (it exits 0 for Compose and Buildx).
    public static func missingTools(_ output: String) -> [String] {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Missing client tools:") }) else { return [] }
        let list = line.dropFirst("Missing client tools:".count).split(separator: ".").first ?? ""
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The first container counts only when it exited 0 and printed the greeting. A pull passes no greeting.
    public static func container(code: Int32, output: String, greeting: String) -> SetupProblem? {
        // Foundation says no string contains "", and the pull step expects no greeting.
        if code == 0, greeting.isEmpty || output.contains(greeting) { return nil }
        let base = SetupProblem.classify(code: code == 0 ? 1 : code, output: output)
        if case .unknown(let detail) = base { return .containerFailed(detail) }
        return base
    }
}
