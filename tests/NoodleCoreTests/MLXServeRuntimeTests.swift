import Foundation
import Testing
@testable import NoodleCore

@Suite(.tags(.slow)) struct MLXServeRuntimeTests {
    /// A scratch Noodle models folder plus a tiny archive shaped like the release tarball.
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-serve-tests-\(UUID().uuidString)", isDirectory: true)
        var models: URL { root.appendingPathComponent("models", isDirectory: true) }
        let version = "99.1.0"

        init() throws { try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// `wrapped` mirrors the release layout: one top folder holding the binary and `lib/`.
        func archive(wrapped: Bool = true, binary: Bool = true) throws -> (url: URL, pin: MLXServeRuntime.Pin) {
            let files = FileManager.default
            let tree = root.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
            let top = wrapped ? tree.appendingPathComponent("mlx-serve-macos-arm64", isDirectory: true) : tree
            try files.createDirectory(at: top.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try Data("dylib".utf8).write(to: top.appendingPathComponent("lib/libmlx.dylib"))
            if binary {
                let exe = top.appendingPathComponent("mlx-serve")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            }
            let url = root.appendingPathComponent("archive-\(UUID().uuidString).tar.gz")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", url.path, "-C", tree.path, "."]
            try tar.run()
            tar.waitUntilExit()
            let size = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return (url, .init(version: version, url: "https://example.invalid/mlx.tar.gz", size: size,
                               sha256: try Digest.sha256(file: url)))
        }
    }

    @Test func pinIsCompleteAndHttps() {
        let pin = MLXServeRuntime.pin
        #expect(pin.url == "https://github.com/ddalcu/mlx-serve/releases/download/v\(pin.version)/mlx-serve-bin-macos-arm64.tar.gz")
        #expect(Digest.isValid(pin.sha256))
        #expect(pin.size == 98_362_127)
        #expect(MLXServeRuntime.version == pin.version)
    }

    @Test func installExtractsWholeTreeAndRunsInPlace() throws {
        let fixture = try Fixture()
        let (archive, pin) = try fixture.archive()
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) == nil)
        let binary = try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: pin)
        #expect(binary == MLXServeRuntime.installation(in: fixture.models, pin: pin).appendingPathComponent("mlx-serve"))
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin)?.path == binary.path)
        let libraries = binary.deletingLastPathComponent().appendingPathComponent("lib/libmlx.dylib")
        #expect(FileManager.default.fileExists(atPath: libraries.path))
    }

    @Test func installAcceptsAFlatArchive() throws {
        let fixture = try Fixture()
        let (archive, pin) = try fixture.archive(wrapped: false)
        _ = try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: pin)
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) != nil)
    }

    @Test func installRejectsAChangedArchiveBeforeExtracting() throws {
        let fixture = try Fixture()
        let (archive, pin) = try fixture.archive()
        let tampered = MLXServeRuntime.Pin(version: pin.version, url: pin.url, size: pin.size,
                                           sha256: "sha256:" + String(repeating: "0", count: 64))
        #expect(throws: MLXServeError.self) { try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: tampered) }
        let wrongSize = MLXServeRuntime.Pin(version: pin.version, url: pin.url, size: pin.size + 1, sha256: pin.sha256)
        #expect(throws: MLXServeError.self) { try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: wrongSize) }
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixture.models.appendingPathComponent("mlx-serve").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func installRefusesAnArchiveWithoutTheBinary() throws {
        let fixture = try Fixture()
        let (archive, pin) = try fixture.archive(binary: false)
        #expect(throws: MLXServeError.self) { try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: pin) }
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) == nil)
    }

    @Test func installClearsPartialInstallsAndSupersededRuntimes() throws {
        let fixture = try Fixture()
        let files = FileManager.default
        let parent = fixture.models.appendingPathComponent("mlx-serve", isDirectory: true)
        let partial = parent.appendingPathComponent(".install-stale", isDirectory: true)
        let older = parent.appendingPathComponent("1.0.0", isDirectory: true)
        let legacy = fixture.models.appendingPathComponent("mlx-runtime/venv/bin", isDirectory: true)
        let separateGGUF = fixture.models.appendingPathComponent("llama.cpp-old", isDirectory: true)
        for directory in [partial, older, legacy, separateGGUF] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        let weights = fixture.models.appendingPathComponent("weights", isDirectory: true)
        try files.createDirectory(at: weights, withIntermediateDirectories: true)
        let (archive, pin) = try fixture.archive()
        _ = try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: pin)
        #expect(!files.fileExists(atPath: partial.path))
        #expect(!files.fileExists(atPath: older.path))
        #expect(!files.fileExists(atPath: fixture.models.appendingPathComponent("mlx-runtime").path))
        #expect(!files.fileExists(atPath: separateGGUF.path))
        #expect(files.fileExists(atPath: weights.path))
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) != nil)
    }

    @Test func reinstallReplacesACorruptCopy() throws {
        let fixture = try Fixture()
        let (archive, pin) = try fixture.archive()
        let target = MLXServeRuntime.installation(in: fixture.models, pin: pin)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: target.appendingPathComponent("mlx-serve"))
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) == nil)
        _ = try MLXServeRuntime.install(archive: archive, into: fixture.models, pin: pin)
        #expect(MLXServeRuntime.executable(in: fixture.models, pin: pin) != nil)
    }

    @Test func downloadFailureNamesTheURL() {
        let message = MLXServeRuntime.downloadFailure(MLXServeRuntime.pin, "offline").description
        #expect(message == "Cannot download MLX support from \(MLXServeRuntime.pin.url): offline. Check the connection and try again.")
    }
}
