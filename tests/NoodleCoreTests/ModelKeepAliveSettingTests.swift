import Foundation
import Testing
@testable import NoodleCore

@Suite struct ModelKeepAliveSettingTests {
    @Test func precedenceIsExplicitThenSavedThenDefault() throws {
        let root = scratchPath("keep-alive")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ModelKeepAliveSetting.effective(explicit: nil, root: root) == .default)
        try ModelKeepAliveSetting.set("1h", root: root)
        #expect(ModelKeepAliveSetting.effective(explicit: nil, root: root).seconds == 3600)
        #expect(ModelKeepAliveSetting.effective(explicit: try LocalModelKeepAlive("30s"), root: root).seconds == 30)
        try ModelKeepAliveSetting.set(nil, root: root)
        #expect(ModelKeepAliveSetting.effective(explicit: nil, root: root) == .default)
    }

    @Test func presetsRoundTripAndKeepLoadedNeverEvicts() throws {
        let root = scratchPath("keep-alive")
        defer { try? FileManager.default.removeItem(at: root) }
        for preset in ModelKeepAliveSetting.presets {
            try ModelKeepAliveSetting.set(preset.duration, root: root)
            #expect(ModelKeepAliveSetting.savedText(root: root) == preset.duration)
        }
        #expect(try ModelKeepAliveSetting.saved(root: root)?.idleEvictSeconds() == nil)
    }

    @Test func rejectsInvalidAndIgnoresCorruptFiles() throws {
        let root = scratchPath("keep-alive")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CocoaError.self) { try ModelKeepAliveSetting.set("soon", root: root) }
        try FileManager.default.createDirectory(at: ModelKeepAliveSetting.file(root: root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: ModelKeepAliveSetting.file(root: root))
        #expect(ModelKeepAliveSetting.saved(root: root) == nil)
    }
}
