import Foundation
import Testing
@testable import NoodleApp

struct RegistrySettingsTests {
    @Test func configUsesChosenDirectoryAndOnlyStoredInlineCredentials() async throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = #"{"auths":{"https://index.docker.io/v1/":{"auth":"fixture"},"registry.example.com":{"identitytoken":"fixture"},"empty.example.com":{},"helper.example.com":{"auth":"fixture"}},"credHelpers":{"helper.example.com":"missing"}}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        let result = await RegistrySnapshot.read(environment: ["HOME": "/does-not-exist", "DOCKER_CONFIG": root.path,
                                                                "DOCKER_HOST": "unix:///other", "DOCKER_CONTEXT": "other"],
                                                 listHelpers: false)
        #expect(result.entries.map(\.name) == ["Docker Hub", "registry.example.com"])
        #expect(result.entries.first?.argument == "https://index.docker.io/v1/")
        #expect(result.incomplete)
    }

    @Test func helperConfigurationAloneIsNotASignIn() async throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"credsStore":"osxkeychain","auths":{"registry.example.com":{"auth":"fixture"}}}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        let result = await RegistrySnapshot.read(environment: ["DOCKER_CONFIG": root.path, "PATH": root.path], listHelpers: true)
        #expect(result.entries.isEmpty)
        #expect(result.incomplete)
    }

    @Test func helperListingShowsOnlyStoredServersFromTheirSelectedStore() async throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = #"{"credsStore":"fixture","credHelpers":{"other.example.com":"separate"}}"#
        try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
        let helper = root.appendingPathComponent("docker-credential-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = list ] || exit 2
        printf '%s\\n' '{"registry.example.com":"fixture-account","other.example.com":"stale-account"}'
        printf '%s\\n' 'fixture diagnostic' >&2
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ["DOCKER_CONFIG": root.path, "PATH": root.path]
        let hidden = await RegistrySnapshot.read(environment: environment, listHelpers: false)
        #expect(hidden.entries.isEmpty)
        let listed = await RegistrySnapshot.read(environment: environment, listHelpers: true)
        #expect(listed.entries.map(\.name) == ["registry.example.com"])
        #expect(listed.incomplete)
    }

    @Test func rejectsUnsafeRegistryNames() {
        #expect(RegistrySnapshot.entry("-option") == nil)
        #expect(RegistrySnapshot.entry("https://user:secret@example.com") == nil)
        #expect(RegistrySnapshot.entry("registry.example.com:5000")?.name == "registry.example.com:5000")
    }
}
