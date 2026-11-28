import Foundation
import Testing
import NoodleCore
@testable import NoodleImages
@testable import NoodleEngine

@Suite struct ArchiveTempSafetyTests {
    @Test func truncatedGzipLeavesNoLoadOrImportTempFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NoodlePaths(root: root)
        let engine = Engine(paths: paths)
        let archive = root.appendingPathComponent("truncated.gz")
        try Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0]).write(to: archive)
        await #expect(throws: (any Error).self) { _ = try await engine.imageStore.load(from: archive) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.tmpDir.path).isEmpty)
        await #expect(throws: (any Error).self) { _ = try await engine.importImage(from: archive, repo: "test:latest") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.tmpDir.path).isEmpty)
    }
}
