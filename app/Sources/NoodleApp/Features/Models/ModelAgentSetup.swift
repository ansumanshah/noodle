import Foundation
import NoodleCore

/// Sets a coding agent up for the local server by writing one settings file that Noodle owns. The agent's own
/// settings are never opened or changed: the agent reads this file only when started with `command`, and
/// removing the file undoes the setup.
enum ModelAgentSetup: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code", codex = "Codex"
    var id: Self { self }

    /// `home` is the user's home folder and `environment` the process environment, so tests can point both elsewhere.
    func file(home: URL = FileManager.default.homeDirectoryForCurrentUser,
              environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        func folder(_ variable: String, _ fallback: String) -> URL {
            environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(fallback, isDirectory: true)
        }
        switch self {
        case .claudeCode: return folder("CLAUDE_CONFIG_DIR", ".claude").appendingPathComponent("noodle.json")
        // `codex --profile noodle` layers $CODEX_HOME/noodle.config.toml over the user's config.
        case .codex: return folder("CODEX_HOME", ".codex").appendingPathComponent("noodle.config.toml")
        }
    }

    /// What to type in a terminal. Codex reads its key from the environment, so the key never sits in its file.
    func command(file: URL) -> String {
        switch self {
        case .claudeCode: return "claude --settings \(Self.shellPath(file))"
        case .codex: return "NOODLE_API_KEY=$(noodle model key) codex --profile noodle"
        }
    }

    /// `baseURL` ends in /v1. Claude Code adds /v1/messages itself, so it gets the server root.
    func contents(baseURL: URL, key: String, model: String) throws -> Data {
        let v1 = baseURL.absoluteString
        switch self {
        case .claudeCode:
            let root = v1.hasSuffix("/v1") ? String(v1.dropLast(3)) : v1
            let env = [Self.marker: "1", "ANTHROPIC_BASE_URL": root, "ANTHROPIC_AUTH_TOKEN": key, "ANTHROPIC_MODEL": model,
                       "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_SMALL_FAST_MODEL": model]
            return try JSONSerialization.data(withJSONObject: ["env": env],
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        case .codex:
            return Data("""
            # \(Self.marker): written by Noodle. Start Codex with: codex --profile noodle
            model = \(Self.toml(model))
            model_provider = "noodle"

            [model_providers.noodle]
            name = "Noodle"
            base_url = \(Self.toml(v1))
            env_key = "NOODLE_API_KEY"
            wire_api = "responses"

            """.utf8)
        }
    }

    /// Present in every file Noodle writes. A file at the same path without it is the user's and is left alone.
    static let marker = "NOODLE_SETUP"

    struct NotOurs: LocalizedError {
        let file: URL
        var errorDescription: String? {
            String(localized: "\(ModelAgentSetup.shellPath(file)) already exists and Noodle did not write it. Move it aside, then try again.")
        }
    }

    /// Writes the file, readable by this user only, and returns it. An agent that was never installed gets its folder made.
    @discardableResult
    func install(baseURL: URL, key: String, model: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let target = file(home: home, environment: environment)
        if FileManager.default.fileExists(atPath: target.path), !isInstalled(home: home, environment: environment) {
            throw NotOurs(file: target)
        }
        // The folder belongs to the agent, so its permissions are left as they are.
        try PrivateFile.write(try contents(baseURL: baseURL, key: key, model: model), to: target, ownFolder: false)
        return target
    }

    /// True only for a file Noodle wrote.
    func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (try? String(contentsOf: file(home: home, environment: environment), encoding: .utf8))?.contains(Self.marker) ?? false
    }

    func remove(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard isInstalled(home: home, environment: environment) else { return }
        try FileManager.default.removeItem(at: file(home: home, environment: environment))
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `~/…` for a path under the home folder, single-quoted when it holds anything a shell would split or expand.
    static func shellPath(_ file: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = file.path
        let safe = path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0) }
        if safe, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return safe ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
