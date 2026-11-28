import Foundation
import Testing
@testable import noodle

@Suite struct CLIHelpAndCleanTests {
    @Test func helpFlagWorksDeepInAGroup() {
        #expect(wantsNestedHelp(["runners", "cache", "clear", "--help"]))
        #expect(wantsNestedHelp(["runners", "status", "-h"]))
        #expect(!wantsNestedHelp(["runners", "cache", "clear", "-h"]))
        #expect(!wantsNestedHelp(["runners", "status"]))
        for argv in [["model", "list", "--help"], ["pod", "create", "--name", "x", "--help"], ["machine", "create", "-h"],
                     ["debug", "bench", "--help"], ["status", "--startup", "--help"], ["scan", "alpine", "--help"]] {
            #expect(wantsNestedHelp(argv))
        }
        #expect(!wantsNestedHelp(["model", "run", "gemma4", "what does --help do", "--help"]))
        #expect(!wantsNestedHelp(["nope", "x", "--help"]))
    }

    @Test func forwardingGroupsKeepTheirArguments() {
        #expect(!wantsNestedHelp(["debug", "run", "x", "--help"]))
        #expect(!wantsNestedHelp(["machine", "shell", "m", "--help"]))
        #expect(!wantsNestedHelp(["dev", "x", "--help"]))
        #expect(!wantsNestedHelp(["runners", "status", "--", "--help"]))
    }

    @Test func newestModificationSeesSubfolderWrites() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("newest-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("a/b")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = Date(timeIntervalSinceNow: -7200), fresh = Date(timeIntervalSinceNow: -5)
        let file = sub.appendingPathComponent("f")
        fm.createFile(atPath: file.path, contents: Data())
        for dir in [root, root.appendingPathComponent("a"), sub] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: dir.path) }
        try fm.setAttributes([.modificationDate: fresh], ofItemAtPath: file.path)
        let found = try #require(newestModification(in: root))
        #expect(abs(found.timeIntervalSince(fresh)) < 1)
    }
}
