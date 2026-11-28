import Foundation
import Testing
@testable import NoodleCore

@Suite struct ModelLocationTests {
    @Test func defaultsCustomAndReset() throws {
        let root = try scratchDir("loc").resolvingSymlinksInPath(), other = try scratchDir("loc").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        #expect(ModelLocation.weights(root: root) == ModelLocation.defaultWeights(root: root))
        try ModelLocation.set(other, root: root)
        #expect(ModelLocation.weights(root: root).path == other.path)
        #expect(ModelLocation.unavailable(root: root) == nil)
        try ModelLocation.set(nil, root: root)
        #expect(ModelLocation.custom(root: root) == nil)
    }

    @Test func rejectsMissingFolderAndReportsUnpluggedDrive() throws {
        let root = try scratchDir("loc").resolvingSymlinksInPath(), other = try scratchDir("loc").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ModelLocationError.self) { try ModelLocation.set(other.appendingPathComponent("nope"), root: root) }
        try ModelLocation.set(other, root: root)
        try FileManager.default.removeItem(at: other)
        #expect(ModelLocation.unavailable(root: root)?.path == other.path)
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}
