import Foundation
import Testing
@testable import NoodleEngine

@Suite struct PersistenceSafetyTests {
    private func paths() -> NoodlePaths {
        NoodlePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-persistence-" + UUID().uuidString))
    }

    @Test func corruptStateIsPreservedAndCanBeRetried() async throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: paths.stateFile)
        let engine = Engine(paths: paths)
        do {
            try await engine.start()
            Issue.record("Corrupt state must prevent startup")
        } catch {
            #expect(String(describing: error).contains(paths.stateFile.path))
        }
        await engine.shutdown()
        #expect(try Data(contentsOf: paths.stateFile) == corrupt)
        #expect(await !engine.started)

        var saved = EngineState()
        saved.pending = Engine.PendingRemovals(containers: ["retained"])
        try JSONEncoder.engine.encode(saved).write(to: paths.stateFile)
        try await engine.start()
        #expect(await engine.pendingRemovals.containers == ["retained"])
        await engine.shutdown()
        let persisted = try JSONDecoder.engine.decode(EngineState.self, from: Data(contentsOf: paths.stateFile))
        #expect(persisted.pending?.containers == ["retained"])
    }

    @Test func existingUnreadableStateIsNotReplaced() async throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.stateFile, withIntermediateDirectories: false)
        let engine = Engine(paths: paths)
        do {
            try await engine.start()
            Issue.record("A directory in place of state must prevent startup")
        } catch {
            #expect(String(describing: error).contains(paths.stateFile.path))
        }
        await engine.shutdown()
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.stateFile.path, isDirectory: &directory))
        #expect(directory.boolValue)
        #expect(await !engine.started)
    }

    @Test func freshStateIsCreated() async throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = Engine(paths: paths)
        try await engine.start()
        #expect(await engine.started)
        let state = try JSONDecoder.engine.decode(EngineState.self, from: Data(contentsOf: paths.stateFile))
        #expect(!state.networks.isEmpty)
        await engine.shutdown()
    }
}
