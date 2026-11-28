import Foundation
import Testing
@testable import noodle

/// A model cache linked onto another volume must be skipped without touching it (touching it triggers the macOS prompt).
@Suite struct ExternalCacheVolumeTests {
    @Test func symlinkIntoVolumesIsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-vol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("hub").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Volumes/NoSuchDrive/hf-cache")
        #expect(ModelStore.onOtherVolume(link))
        #expect(ModelStore.onOtherVolume(link + "/models--x"))
        #expect(!ModelStore.onOtherVolume(dir.path))
        #expect(ModelStore.huggingFaceRoot(["HF_HUB_CACHE": link]) == nil)
    }
}
