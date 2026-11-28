import Foundation
import NoodleEngine
import Testing

@Suite("DockerModelRunnerCommand")
struct DockerModelRunnerCommandTests {
    @Test func capturesJSONWithoutStderrAndSetsTheSameHome() async throws {
        let fixture = try commandFixture("""
        #!/bin/sh
        printf 'diagnostic on stderr\n' >&2
        printf '{"home":"%s","arguments":"%s","names":"%s"}\n' "$NOODLE_HOME" "$*" "$NOODLE_LOCAL_NAMES"
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let output = try await DockerModelCommand(home: fixture.home, executable: fixture.binary).run(["list", "--json"])
        let object = try JSONDecoder().decode([String: String].self, from: output)
        #expect(object["home"] == fixture.home.path)
        #expect(object["arguments"] == "model list --json")
        #expect(object["names"] == "0")
    }

    @Test func refusesMissingSiblingBinary() async throws {
        do {
            _ = try await DockerModelCommand(home: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/noodle-missing-" + UUID().uuidString)).run(["list", "--json"])
            Issue.record("Missing CLI was accepted")
        } catch let error as DockerModelRunnerError { #expect(error.status == 503) }
    }

    @Test func doesNotDecodeTruncatedCommandOutput() async throws {
        let fixture = try commandFixture("""
        #!/bin/sh
        /usr/bin/yes x | /usr/bin/head -c 1048577
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        do {
            _ = try await DockerModelCommand(home: fixture.home, executable: fixture.binary).run(["list", "--json"])
            Issue.record("Oversized command output was accepted")
        } catch let error as DockerModelRunnerError { #expect(error.status == 502) }
    }

    @Test func failureDoesNotExposeCommandCredentials() async throws {
        let fixture = try commandFixture("""
        #!/bin/sh
        printf 'private-model-key\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        do {
            _ = try await DockerModelCommand(home: fixture.home, executable: fixture.binary).run(["endpoint", "--json"])
            Issue.record("Failed command was accepted")
        } catch let error as DockerModelRunnerError {
            #expect(error.status == 500)
            #expect(!error.description.contains("private-model-key"))
        }
    }

    private func commandFixture(_ script: String) throws -> (home: URL, binary: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-dmr-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let binary = home.appendingPathComponent("noodle")
        try Data((script + "\n").utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (home, binary)
    }
}
