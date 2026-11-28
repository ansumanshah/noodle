import Darwin
import Foundation
import Testing
@testable import NoodleApp

/// Exercises the real CLI with isolated HOME/NOODLE_HOME and launchctl disabled. No VM or network.
/// Enable after building noodle with NOODLE_SETUP_TEST_CLI=/absolute/path/to/noodle.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOODLE_SETUP_TEST_CLI"] != nil))
struct SetupUninstallSafetyTests {
    private struct Fixture {
        let directory: URL
        var home: URL { directory.appendingPathComponent("home") }
        var data: URL { directory.appendingPathComponent("data") }
        var receipt: URL { data.appendingPathComponent("setup.json") }
    }

    private func fixture() throws -> Fixture {
        let fixture = Fixture(directory: FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-safety-\(UUID())"))
        for directory in [fixture.home, fixture.data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "dev.getnoodle.data.v1\n".write(to: fixture.data.appendingPathComponent(".noodle-data"), atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: fixture.receipt)
        return fixture
    }

    private func uninstall(_ fixture: Fixture, root: URL? = nil, deleteData: Bool = false) async throws -> CLI.Result {
        let cli = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOODLE_SETUP_TEST_CLI"]))
        try #require(FileManager.default.isExecutableFile(atPath: cli.path), "Build the root package's noodle product before running these tests")
        let arguments = UninstallNoodle.arguments(deleteData: deleteData)
        return await Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = fixture.home.path
            environment["NOODLE_HOME"] = (root ?? fixture.data).path
            environment["NOODLE_NO_LAUNCHCTL"] = "1"
            environment["NOODLE_LAUNCHCTL"] = nil
            environment["DOCKER_CONFIG"] = fixture.directory.appendingPathComponent("docker").path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return .init(code: 126, output: error.localizedDescription) }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(code: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
        }.value
    }

    @Test(arguments: [false, true]) func refusesRunningLinuxMachineBeforeCleanup(deleteData: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let machine = fixture.data.appendingPathComponent("machines/dev")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        let lock = open(machine.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { close(lock) }
        let result = try await uninstall(fixture, deleteData: deleteData)
        #expect(result.code != 0 && result.output.contains("Linux machine dev is running"))
        #expect(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    @Test func refusesUnmarkedFolderAndProtectedRootsEvenWithMarker() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let marker = fixture.data.appendingPathComponent(".noodle-data")
        try FileManager.default.removeItem(at: marker)
        let unverified = try await uninstall(fixture, deleteData: true)
        #expect(unverified.code != 0 && unverified.output.contains("unverified Noodle data folder"))
        for root in [fixture.home, fixture.directory, URL(fileURLWithPath: "/")] {
            if root.path != "/" {
                try "dev.getnoodle.data.v1\n".write(to: root.appendingPathComponent(".noodle-data"), atomically: true, encoding: .utf8)
            }
            let result = try await uninstall(fixture, root: root, deleteData: true)
            #expect(result.code != 0 && result.output.contains("protected data folder"))
        }
        let alias = fixture.directory.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let symlink = try await uninstall(fixture, root: alias, deleteData: true)
        #expect(symlink.code != 0 && symlink.output.contains("protected data folder"))
        for root in [URL(fileURLWithPath: fixture.home.path.uppercased()), FileManager.default.homeDirectoryForCurrentUser] {
            let protected = try await uninstall(fixture, root: root, deleteData: true)
            #expect(protected.code != 0 && protected.output.contains("protected data folder"))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    @Test func deletesOnlyVerifiedDataAndKeepsOutsideFiles() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let outside = fixture.home.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: outside)
        let result = try await uninstall(fixture, deleteData: true)
        #expect(result.code == 0, "\(result.output)")
        #expect(!FileManager.default.fileExists(atPath: fixture.data.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func profileWriteFailureKeepsReceiptAndRetrySucceeds() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let profileDirectory = fixture.home.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let profile = profileDirectory.appendingPathComponent(".zprofile")
        let block = "\n# >>> Noodle PATH >>>\nexport PATH=fixture\n# <<< Noodle PATH <<<\n"
        try ("export KEEP=1\n" + block).write(to: profile, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(["profile:" + profile.path: block]).write(to: fixture.receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: profileDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profileDirectory.path) }
        let failed = try await uninstall(fixture)
        #expect(failed.code != 0 && failed.output.contains("cannot clean PATH profile"))
        #expect(FileManager.default.fileExists(atPath: fixture.receipt.path))
        #expect(try String(contentsOf: profile, encoding: .utf8).contains(block))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profileDirectory.path)
        let retried = try await uninstall(fixture)
        #expect(retried.code == 0, "\(retried.output)")
        #expect(!FileManager.default.fileExists(atPath: fixture.receipt.path))
        #expect(try String(contentsOf: profile, encoding: .utf8) == "export KEEP=1\n")
    }
}
