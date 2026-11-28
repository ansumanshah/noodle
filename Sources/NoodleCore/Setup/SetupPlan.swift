import Foundation

/// First-run decisions as plain values: what is installed, what to download, which flags to pass.
/// No process, file or network access happens here, so every rule is unit-tested.

public struct SetupTool: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String          // docker, docker-compose, docker-buildx, docker-model
    public let path: String?         // nil when this Mac has no usable copy
    public let version: String?      // as the tool reports it, when it was found and answered
    public init(name: String, path: String?, version: String? = nil) {
        self.name = name; self.path = path; self.version = version
    }
    public var found: Bool { path != nil }
    /// The short name people use for it.
    public var title: String {
        switch name {
        case "docker": "Docker CLI"
        case "docker-compose": "Compose"
        case "docker-model": "Model Runner"
        default: "Buildx"
        }
    }
    /// "Docker CLI 29.9.3" when the version is known.
    public var label: String { version.map { title + " " + $0 } ?? title }

    /// The first dotted version in a tool's `--version` or `version` output, without a leading v.
    public static func parseVersion(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?:version\s+|\sv|^v)(\d+\.\d+(?:\.\d+)?)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
}

/// Another engine's Docker context that this Mac already has.
public struct SetupEngine: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String          // context name, or "default"
    public let socket: String
    public let reachable: Bool       // its socket answered a ping; we never start an engine
    public let inUse: Bool           // it is the context `docker` currently talks to
    public let inventory: ImportInventory?   // what it holds, counted over its socket while it runs
    public init(name: String, socket: String, reachable: Bool, inUse: Bool, inventory: ImportInventory? = nil) {
        self.name = name; self.socket = socket; self.reachable = reachable; self.inUse = inUse; self.inventory = inventory
    }
    /// A running engine with something worth copying.
    public var canImport: Bool { reachable && inventory.map { !$0.isEmpty } ?? false }
    /// A person-readable name: "Docker Desktop" for its context, else the context name.
    public var displayName: String {
        switch name {
        case "desktop-linux": "Docker Desktop"
        case "orbstack": "OrbStack"
        case "colima": "Colima"
        case "default": "your other engine"
        default: name
        }
    }
}

public struct SetupDetection: Sendable, Equatable {
    public var tools: [SetupTool]
    public var engines: [SetupEngine]
    public var shell: String
    public var pathNeeded: Bool
    /// DOCKER_CONTEXT or DOCKER_HOST, when set: plain `docker` then ignores the context setup selects.
    public var dockerOverride: String?
    public init(tools: [SetupTool], engines: [SetupEngine] = [], shell: String = "/bin/zsh", pathNeeded: Bool = true,
                dockerOverride: String? = nil) {
        self.tools = tools; self.engines = engines; self.shell = shell; self.pathNeeded = pathNeeded
        self.dockerOverride = dockerOverride
    }
    public func tool(_ name: String) -> SetupTool? { tools.first { $0.name == name } }
    public var missing: [SetupTool] { tools.filter { !$0.found } }
    public var dockerMissing: Bool { !(tool("docker")?.found ?? false) }
    public var importable: [SetupEngine] { engines.filter(\.canImport) }
    /// The engine to offer: the one in use, else the first running one with items.
    public var importSource: SetupEngine? { importable.first(where: \.inUse) ?? importable.first }
}

public struct SetupPlan: Sendable, Equatable {
    public let missing: [String]
    public let sizes: [String: Int64]

    public static func make(_ detection: SetupDetection, sizes: [String: Int64]) -> SetupPlan {
        SetupPlan(missing: detection.missing.map(\.name), sizes: sizes)
    }

    public var needsDownload: Bool { !missing.isEmpty }
    /// Nil when any size is unknown: the sheet then says so instead of guessing.
    public var downloadBytes: Int64? {
        let known = missing.compactMap { sizes[$0] }
        return known.count == missing.count ? known.reduce(0, +) : nil
    }
    public func size(of name: String) -> Int64? { sizes[name] }

    /// The exact arguments for `noodle`, built only from existing flags.
    public static func flags(download: Bool, addPath: Bool, useDefault: Bool) -> [String] {
        ["setup"] + (download ? ["--tools"] : []) + (addPath ? ["--path"] : []) + [useDefault ? "--use" : "--no-use"]
    }

    // MARK: default engine

    /// On only when no other engine is in use. The reason is one plain line when it stays off.
    public static func defaultEngine(_ engines: [SetupEngine]) -> (on: Bool, reason: String?) {
        guard let other = engines.first(where: \.inUse) else { return (true, nil) }
        let name = other.name == "default" ? "Another Docker engine" : other.displayName
        return (false, "\(name) is your current engine. It stays untouched.")
    }

    // MARK: terminal PATH

    public static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    /// The profile `noodle setup --path` edits. Nil for shells it refuses (fish and others).
    public static func profileName(shell: String, existing: Set<String> = []) -> String? {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh": ".zprofile"
        case "bash": [".bash_profile", ".bash_login", ".profile"].first(where: existing.contains) ?? ".bash_profile"
        default: nil
        }
    }

    /// The startup files the given shell reads. Another shell's files say nothing about this one.
    public static func startupFiles(shell: String) -> [String] {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh": [".zshenv", ".zprofile", ".zshrc"]
        case "bash": [".bash_profile", ".bash_login", ".profile", ".bashrc"]
        default: [".profile"]
        }
    }

    /// True unless one of these texts runs a line that puts ~/.local/bin on PATH. Comments do not count.
    /// For the files a shell really reads, use `pathNeeded(shell:files:)`.
    public static func pathNeeded(profileTexts: [String]) -> Bool {
        !putsOnPath(profileTexts.joined(separator: "\n"))
    }
}
