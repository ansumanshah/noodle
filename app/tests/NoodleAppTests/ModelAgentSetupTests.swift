import Foundation
import Testing
@testable import NoodleApp

struct ModelAgentSetupTests {
    private let url = URL(string: "http://127.0.0.1:11345/v1")!

    @Test func writesOnlyItsOwnPrivateFileAndRemoveDeletesIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-setup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let own = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: own)

        for agent in ModelAgentSetup.allCases {
            let file = try agent.install(baseURL: url, key: "k\"ey", model: "qwen3.5-4b", home: home, environment: [:])
            #expect(file.path.hasPrefix(home.path) && file.lastPathComponent.hasPrefix("noodle."))
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
            #expect(agent.isInstalled(home: home, environment: [:]))
            try agent.remove(home: home, environment: [:])
            #expect(!agent.isInstalled(home: home, environment: [:]))
        }
        // A file of the same name that Noodle did not write is never replaced or deleted.
        let foreign = ModelAgentSetup.claudeCode.file(home: home, environment: [:])
        try Data("{}".utf8).write(to: foreign)
        #expect(!ModelAgentSetup.claudeCode.isInstalled(home: home, environment: [:]))
        #expect(throws: ModelAgentSetup.NotOurs.self) {
            try ModelAgentSetup.claudeCode.install(baseURL: url, key: "k", model: "m", home: home, environment: [:])
        }
        try ModelAgentSetup.claudeCode.remove(home: home, environment: [:])
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "{}")
        // The agent's own folder keeps its permissions, and its settings are untouched.
        #expect(try FileManager.default.attributesOfItem(atPath: own.deletingLastPathComponent().path)[.posixPermissions] as? Int != 0o700)
        #expect(try String(contentsOf: own, encoding: .utf8) == #"{"model":"opus"}"#)
    }

    @Test func claudeCodeGetsTheServerRootAndCodexKeepsTheKeyOutOfItsFile() throws {
        let claude = try JSONSerialization.jsonObject(
            with: ModelAgentSetup.claudeCode.contents(baseURL: url, key: #"se"cret"#, model: "m")) as? [String: [String: String]]
        #expect(claude?["env"]?["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11345")
        #expect(claude?["env"]?["ANTHROPIC_AUTH_TOKEN"] == #"se"cret"#)
        let codex = String(decoding: try ModelAgentSetup.codex.contents(baseURL: url, key: "secret", model: #"a"b"#), as: UTF8.self)
        #expect(!codex.contains("secret"))
        #expect(codex.contains(#"model = "a\"b""#) && codex.contains(#"base_url = "http://127.0.0.1:11345/v1""#))
    }

    @Test func respectsTheAgentsOwnHomeVariables() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(ModelAgentSetup.codex.file(home: home, environment: ["CODEX_HOME": "/tmp/c"]).path == "/tmp/c/noodle.config.toml")
        #expect(ModelAgentSetup.claudeCode.file(home: home, environment: [:]).path == "/Users/x/.claude/noodle.json")
        #expect(ModelAgentSetup.shellPath(URL(fileURLWithPath: "/tmp/a b/noodle.json")) == "'/tmp/a b/noodle.json'")
    }
}
