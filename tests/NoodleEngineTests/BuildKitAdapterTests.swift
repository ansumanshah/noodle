import Foundation
import Testing
import NoodleEngine
@testable import NoodleAPI
@testable import NoodleCore

@Suite(.tags(.slow)) struct BuildKitAdapterTests {
    private struct Fixture {
        let root: URL
        let resources: URL
        let executable: URL
        let archive: URL
        let paths: NoodlePaths

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-adapter-" + UUID().uuidString)
            resources = root.appendingPathComponent("dev")
            executable = root.appendingPathComponent("Noodle.app/Contents/MacOS/noodled")
            archive = root.appendingPathComponent("adapter.tar.gz")
            paths = NoodlePaths(root: root.appendingPathComponent("home"), resources: resources)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        }

        func adapter() -> BuildKitAdapter {
            BuildKitAdapter(paths: paths, environment: ["NOODLE_RESOURCES": resources.path], executableURL: executable)
        }

        func binary(_ url: URL, text: String = "#!/bin/sh\nexit 0\n") throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func pack() throws {
            let source = root.appendingPathComponent("source")
            try binary(source.appendingPathComponent(BuildKitAdapter.name))
            try Data("Fixture licenses\n".utf8).write(to: source.appendingPathComponent("BuildKitAdapter-Licenses.txt"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", archive.path, "-C", source.path, BuildKitAdapter.name, "BuildKitAdapter-Licenses.txt"]
            process.environment = ["COPYFILE_DISABLE": "1"]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func manifest(overrides: [String: Any] = [:]) throws -> Data {
            var pin: [String: Any] = ["version": "0.2.0", "url": archive.absoluteString,
                "size": try Data(contentsOf: archive).count, "sha256": Digest.split(try Digest.sha256(file: archive)).1]
            pin.merge(overrides) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: ["buildkit": pin])
            try data.write(to: resources.appendingPathComponent("on-demand.json"))
            return data
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func waitFor(_ condition: () async throws -> Bool) async throws {
        // Generous: this only waits for the fixture process to start, which is slow when the whole suite runs on a busy Mac.
        guard try await waitUntil(timeout: .seconds(20), condition) else { throw BuildKitAdapterError("fixture timed out") }
    }

    private func stalled(_ fixture: Fixture) throws -> (BuildKitAdapter, URL) {
        try fixture.pack()
        _ = try fixture.manifest()
        let pid = fixture.root.appendingPathComponent("curl.pid")
        let script = fixture.root.appendingPathComponent("curl")
        try fixture.binary(script, text: "#!/bin/sh\necho $$ > '\(pid.path)'\nexec /bin/sleep 60\n")
        var adapter = fixture.adapter()
        adapter.curlExecutable = script
        return (adapter, pid)
    }

    @Test func cancellationLeavesOtherWaitersRunningAndStopsTheLastDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (adapter, pidFile) = try stalled(fixture)
        let downloads = BuildKitAdapterDownloads()
        let first = Task { try await downloads.install(adapter) }
        let second = Task { try await downloads.install(adapter) }
        try await waitFor { await downloads.waiterCount == 2 && FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(kill(pid, 0) == 0)
        #expect(await downloads.waiterCount == 1)
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        try await waitFor { kill(pid, 0) != 0 }
        #expect(await downloads.waiterCount == 0)
        // The cancelled install releases its lock and permits an immediate real-file retry.
        _ = try await downloads.install(fixture.adapter())
    }

    @Test func shutdownDrainsARequestWithAStalledAdapterDownloadPromptly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (adapter, pidFile) = try stalled(fixture)
        let engine = Engine(paths: fixture.paths)
        let connections = HTTPConnections()
        let request = Task {
            do { _ = try await engine.prepareNativeBuildAdapter(using: adapter); Issue.record("expected cancellation") }
            catch is CancellationError {}
            catch { Issue.record("unexpected error: \(error)") }
        }
        connections.addTask(request, id: UUID())
        try await waitFor { FileManager.default.fileExists(atPath: pidFile.path) }
        let start = ContinuousClock.now
        connections.cancelTasks() // DockerServer.stopAccepting uses this before draining tasks.
        await request.value
        #expect(start.duration(to: .now) < .seconds(1))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await waitFor { kill(pid, 0) != 0 }
    }

    @Test func cancellationDoesNotWaitForAnotherProcessesInstallLock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        _ = try fixture.manifest()
        let directory = Tools.directory(fixture.paths).appendingPathComponent("buildkit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let downloads = BuildKitAdapterDownloads()
        let request = Task { try await downloads.install(fixture.adapter()) }
        try await waitFor { await downloads.waiterCount == 1 }
        let start = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await downloads.waiterCount == 0)
    }

    @Test func oversizedStreamWithoutALengthIsStoppedAtThePin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        _ = try fixture.manifest(overrides: ["size": 7])
        var adapter = fixture.adapter()
        // An endless decoded body, without any Content-Length information.
        let script = fixture.root.appendingPathComponent("curl")
        try fixture.binary(script, text: "#!/bin/sh\nexec /usr/bin/yes oversized-response\n")
        adapter.curlExecutable = script
        do { _ = try adapter.install(); Issue.record("expected the size limit") }
        catch { #expect(error.localizedDescription.contains("exceeds its pinned size of 7 bytes")) }
        let directory = Tools.directory(fixture.paths).appendingPathComponent("buildkit")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["install.lock"])
    }

    @Test func sameVersionArchiveCannotReplacePublishedBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let binary = source.appendingPathComponent(BuildKitAdapter.name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        try Data("fixture licenses".utf8).write(to: source.appendingPathComponent("BuildKitAdapter-Licenses.txt"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-buildkit-adapter.sh")
        let archive = fixture.root.appendingPathComponent("Noodle-0.2.0-buildkit-darwin-arm64.tar.gz")
        func pack() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, source.path, "--archive", archive.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["NOODLE_SIGN_IDENTITY": "-", "NOODLE_TIMESTAMP": "0"]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try pack() == 0)
        let original = try Digest.sha256(file: archive)
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: binary)
        #expect(try pack() != 0)
        #expect(try Digest.sha256(file: archive) == original)
    }

    @Test func parsesSealedManifestAndRejectsInvalidPins() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        let pin = try BuildKitAdapterPin.decode(fixture.manifest())
        #expect(pin.version == "0.2.0")
        #expect(pin.url == fixture.archive)
        #expect(pin.size == Int64(try Data(contentsOf: fixture.archive).count))
        let invalidPins: [[String: Any]] = [
            ["version": ""], ["size": 0], ["size": -1], ["size": "100"],
            ["sha256": "broken"], ["sha256": String(repeating: "A", count: 64)],
            ["url": "http://example.com/adapter.tar.gz"], ["url": "ftp://localhost/adapter"],
            ["url": "https://user:password@example.com/adapter.tar.gz"]
        ]
        for invalid in invalidPins {
            let data = try fixture.manifest(overrides: invalid)
            #expect(throws: (any Error).self) { try BuildKitAdapterPin.decode(data) }
        }
        #expect(throws: (any Error).self) { try BuildKitAdapterPin.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try BuildKitAdapterPin.decode(Data("{".utf8)) }
    }

    @Test func verifiesLengthAndHashBeforeExtraction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        let pin = try BuildKitAdapterPin.decode(fixture.manifest())
        try pin.verify(fixture.archive)
        let original = try Data(contentsOf: fixture.archive)
        try original.dropLast().write(to: fixture.archive)
        #expect(throws: (any Error).self) { try pin.verify(fixture.archive) }
        var changed = original
        changed[changed.startIndex] ^= 0xff
        try changed.write(to: fixture.archive)
        #expect(throws: (any Error).self) { try pin.verify(fixture.archive) }
        // A valid pin for non-tar bytes still cannot produce an installed executable.
        _ = try fixture.manifest()
        #expect(throws: (any Error).self) { try fixture.adapter().install() }
        #expect(try fixture.adapter().executable() == nil)
    }

    @Test func lookupPrefersDevelopmentThenLegacyBundleThenVerifiedCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        _ = try fixture.manifest()
        let adapter = fixture.adapter()
        #expect(try adapter.executable() == nil)
        let downloaded = try adapter.install()
        #expect(try adapter.executable() == downloaded)
        let legacy = fixture.executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/" + BuildKitAdapter.name)
        try fixture.binary(legacy)
        #expect(try adapter.executable() == legacy)
        let development = fixture.resources.appendingPathComponent(BuildKitAdapter.name)
        try fixture.binary(development)
        #expect(try adapter.executable() == development)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: development.path)
        #expect(try adapter.executable() == legacy)
        try FileManager.default.removeItem(at: fixture.resources.appendingPathComponent("on-demand.json"))
        #expect(try adapter.install() == legacy) // old bundles need no manifest or network
    }

    @Test func resolvesManifestThroughInstalledCLISymlink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        let data = try fixture.manifest()
        let contents = fixture.executable.deletingLastPathComponent().deletingLastPathComponent()
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try data.write(to: resources.appendingPathComponent("on-demand.json"))
        let cli = contents.appendingPathComponent("Helpers/noodle")
        try fixture.binary(cli)
        let link = fixture.root.appendingPathComponent("noodle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        let adapter = BuildKitAdapter(paths: NoodlePaths(root: fixture.paths.root), environment: [:], executableURL: link)
        #expect(try adapter.pin().url == fixture.archive)
        #expect(try adapter.install().path.hasPrefix(Tools.directory(fixture.paths).path))
    }

    @Test func installRejectsWrongSizeAndHash() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        let invalidPins: [[String: Any]] = [["size": 1], ["sha256": String(repeating: "0", count: 64)]]
        for overrides in invalidPins {
            _ = try fixture.manifest(overrides: overrides)
            #expect(throws: BuildKitAdapterError.self) { try fixture.adapter().install() }
            #expect(try fixture.adapter().executable() == nil)
        }
    }

    @Test func reusesVerifiedCacheAndRefetchesCorruptOrPartialFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        _ = try fixture.manifest()
        let adapter = fixture.adapter()
        var downloads = 0
        let binary = try adapter.install { _ in downloads += 1 }
        #expect(downloads == 1)
        #expect(try adapter.install { _ in downloads += 1 } == binary)
        #expect(downloads == 1)
        try Data("corrupt".utf8).write(to: binary)
        #expect(try adapter.executable() == nil)
        #expect(try adapter.install { _ in downloads += 1 } == binary)
        #expect(downloads == 2)
        let archive = binary.deletingLastPathComponent().appendingPathComponent("archive.tar.gz")
        try Data([0]).write(to: archive)
        #expect(try adapter.executable() == nil)
        _ = try adapter.install { _ in downloads += 1 }
        #expect(downloads == 3)
        let licenses = binary.deletingLastPathComponent().appendingPathComponent("BuildKitAdapter-Licenses.txt")
        try Data("damaged notice".utf8).write(to: licenses)
        _ = try adapter.install { _ in downloads += 1 }
        #expect(downloads == 4)
        #expect(try String(contentsOf: licenses, encoding: .utf8) == "Fixture licenses\n")
        try FileManager.default.removeItem(at: fixture.archive)
        #expect(try adapter.install() == binary) // no upstream file is needed after install
        #expect(binary.path.hasPrefix(Tools.directory(fixture.paths).path + "/"))
    }

    @Test func failedDownloadNamesURLAndLeavesNoPartialInstall() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.pack()
        _ = try fixture.manifest()
        try FileManager.default.removeItem(at: fixture.archive)
        do {
            _ = try fixture.adapter().install()
            Issue.record("missing fixture archive should fail")
        } catch {
            #expect(error.localizedDescription.contains(fixture.archive.absoluteString))
            #expect(error.localizedDescription.contains("noodle tools install " + BuildKitAdapter.toolName))
        }
        #expect(try fixture.adapter().executable() == nil)
        let directory = Tools.directory(fixture.paths).appendingPathComponent("buildkit")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["install.lock"])
    }
}
