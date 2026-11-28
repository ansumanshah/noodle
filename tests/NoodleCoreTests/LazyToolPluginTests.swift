import Foundation
import Testing
@testable import NoodleCore

@Suite struct LazyToolPluginTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-lazy-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func metadataMatchesDockerPluginProtocol() throws {
        for name in ["docker-compose", "docker-buildx"] {
            let text = try #require(LazyToolPlugin.metadata(name))
            let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
            #expect(fields["SchemaVersion"] == "0.1.0")
            #expect(fields["Vendor"] == "Docker Inc.")
            #expect(fields["Version"] == "v" + Tools.pins.first { $0.name == name }!.version)
            #expect(fields["ShortDescription"] == (name == "docker-compose" ? "Docker Compose" : "Docker Buildx"))
        }
        #expect(LazyToolPlugin.metadata("docker") == nil)
        #expect(LazyToolPlugin.metadata("other") == nil)
    }

    @Test func detectsStubThroughLinkAndReplacesAtomically() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        let stub = root.appendingPathComponent("stub")
        try LazyToolPlugin.script("docker-compose", cli: root.appendingPathComponent("noodle"), paths: paths)
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let link = root.appendingPathComponent("docker-compose")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stub)
        #expect(LazyToolPlugin.isStub(link, name: "docker-compose"))
        #expect(!LazyToolPlugin.isStub(link, name: "docker-buildx"))
        let real = root.appendingPathComponent("real")
        try "#!/bin/sh\nexit 0\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try LazyToolPlugin.replace(link, with: real)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(!LazyToolPlugin.isStub(link, name: "docker-compose"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".noodle-plugin-") })
    }

    @Test func discoveryDoesNotExecuteStubOrDocker() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config/cli-plugins")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let paths = NoodlePaths(root: root)
        let cli = root.appendingPathComponent("home/.local/bin/noodle")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 87\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let managed = LazyToolPlugin.directory(paths)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let stub = managed.appendingPathComponent("docker-compose")
        try LazyToolPlugin.script("docker-compose", cli: cli, paths: paths)
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let link = config.appendingPathComponent("docker-compose")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stub)
        let receipt = ["link:" + link.path: stub.path, "cli-sha256": try Digest.sha256(file: cli)]
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("setup.json"))
        let discovery = ToolDiscovery(env: ["HOME": root.path + "/home", "DOCKER_CONFIG": config.deletingLastPathComponent().path], paths: paths)
        #expect(discovery.lazyPlugin("docker-compose") == link.path)
        #expect(discovery.compatible(link.path, name: "docker-compose"))
        #expect(discovery.plugin("docker-compose", worksUnder: "/does/not/exist"))
        try FileManager.default.removeItem(at: cli)
        #expect(discovery.lazyPlugin("docker-compose") == nil)
        #expect(!discovery.compatible(link.path, name: "docker-compose"))
        #expect(!discovery.plugin("docker-compose", worksUnder: "/does/not/exist"))
        try "#!/bin/sh\nexit 88\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        #expect(!discovery.compatible(link.path, name: "docker-compose"))
    }

    @Test func stubQuotesInstallationPathsAndPreservesInput() throws {
        let root = try fixture().appendingPathComponent("a space and a ' quote")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("noodle")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" \"$TOOL_TEST_VALUE\"\nexec /bin/cat\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("docker-compose")
        try LazyToolPlugin.script("docker-compose", cli: cli, paths: NoodlePaths(root: root))
            .write(to: stub, atomically: true, encoding: .utf8)
        for file in [cli, stub] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = stub
        process.arguments = ["compose", "-f", "-", "an argument with spaces"]
        process.environment = ["TOOL_TEST_VALUE": "environment preserved"]
        process.standardOutput = output; process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("stdin preserved\n".utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: result, as: UTF8.self) ==
            "__tool-plugin\ndocker-compose\n\(root.path)\n\(stub.path)\ncompose\n-f\n-\nan argument with spaces\nenvironment preserved\nstdin preserved\n")
    }

    @Test func installLockExcludesAnotherDescriptorAndReleasesOnClose() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root.appendingPathComponent("noodle"))
        let other = open(ToolInstallLock.file(paths).path, O_CREAT | O_RDWR, 0o600)
        #expect(other >= 0)
        defer { close(other) }
        do {
            let lock = try ToolInstallLock(paths: paths)
            withExtendedLifetime(lock) {
                #expect(flock(other, LOCK_EX | LOCK_NB) == -1)
                #expect(errno == EWOULDBLOCK)
            }
        }
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0)
    }

    @Test(arguments: [false, true]) func linkOwnershipSurvivesReceiptFailure(afterRename: Bool) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("docker-compose")
        let original = root.appendingPathComponent("stub")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        var receipt = ["link:" + link.path: original.path]
        do {
            try LazyToolPlugin.replaceOwned(link, with: real, receipt: receipt) { key, value in
                if key.hasPrefix(afterRename ? "link:" : "pending-link:") { throw POSIXError(.ENOSPC) }
                receipt[key] = value
            }
            Issue.record("receipt failure was not injected")
        } catch { #expect(error is POSIXError) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == (afterRename ? real.path : original.path))
        #expect(LazyToolPlugin.owns(link, receipt: receipt))
        if LazyToolPlugin.owns(link, receipt: receipt) { try FileManager.default.removeItem(at: link) }
        #expect(!FileManager.default.fileExists(atPath: link.path))
    }

    @Test func lockKeepsTheSameInodeAfterDataRemoval() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root.appendingPathComponent("noodle"))
        let lock = try ToolInstallLock(paths: paths)
        try FileManager.default.createDirectory(at: Tools.directory(paths), withIntermediateDirectories: true)
        let file = ToolInstallLock.file(paths)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        try FileManager.default.removeItem(at: paths.root)
        try FileManager.default.createDirectory(at: Tools.directory(paths), withIntermediateDirectories: true)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode)
        let second = open(file.path, O_RDWR)
        defer { close(second) }
        withExtendedLifetime(lock) { #expect(flock(second, LOCK_EX | LOCK_NB) == -1) }
    }
}
