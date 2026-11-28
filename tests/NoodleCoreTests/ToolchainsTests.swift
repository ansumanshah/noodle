import Foundation
import Testing
@testable import NoodleCore

@Suite struct ToolchainsTests {
    @Test(arguments: [
        ("Node", "v22.11.0", "22.11.0"),
        ("Bun", "1.3.2", "1.3.2"),
        ("Python", "Python 3.13.1", "3.13.1"),
        ("Rust", "rustc 1.82.0 (f6e511eec 2024-10-15)", "1.82.0"),
        ("Cargo", "cargo 1.82.0 (8f40fc59f 2024-08-21)", "1.82.0"),
        ("Go", "go version go1.23.2 darwin/arm64", "1.23.2"),
        ("Ruby", "ruby 3.3.5 (2024-09-03 revision ef084cc8f4) [arm64-darwin24]", "3.3.5"),
        ("CocoaPods", "1.16.2", "1.16.2"),
        ("CocoaPods", "\u{1B}[33mWARNING: needs UTF-8\u{1B}[0m\n1.17.0", "1.17.0"),
        ("Docker", "Docker version 27.3.1, build ce12230", "27.3.1"),
        ("Swift", "swift-driver version: 1.115 Apple Swift version 6.0.2 (swiftlang-6.0.2.1.2 clang-1600.0.26.4)\nTarget: arm64-apple-macosx15.0", "6.0.2"),
    ])
    func parsesVersionOutput(tool: String, output: String, expected: String) {
        #expect(Toolchains.version(tool: tool, from: output) == expected)
    }

    @Test func unparsableOutputIsNil() {
        #expect(Toolchains.version(tool: "Node", from: "command not found") == nil)
        #expect(Toolchains.version(tool: "Swift", from: "swift-driver version: 1.115") == nil)
    }

    private func inv(_ tools: [String: String], other: [String] = []) -> ToolchainInventory {
        ToolchainInventory(tools: tools, otherXcodes: other)
    }

    @Test func identicalInventoriesHaveNoChanges() {
        let a = inv(["Xcode": "26.1", "Node": "22.1.0"], other: ["25.4"])
        #expect(Toolchains.changes(from: a, to: a).isEmpty)
    }

    @Test func reportsChangedAddedAndRemoved() {
        let old = inv(["Xcode": "26.1", "Node": "22.1.0", "Go": "1.23.2"], other: ["25.4"])
        let new = inv(["Xcode": "26.2", "Node": "22.1.0", "Bun": "1.3.2"], other: ["26.1"])
        #expect(Toolchains.changes(from: old, to: new) == [
            "Xcode 26.1 -> 26.2", "Bun added (1.3.2)", "Go removed (was 1.23.2)", "Xcode 26.1 installed", "Xcode 25.4 removed",
        ])
    }

    @Test func snapshotKeepsLastChangesUntilNewOnes() {
        let t0 = Date(timeIntervalSince1970: 0), t1 = Date(timeIntervalSince1970: 1000), t2 = Date(timeIntervalSince1970: 2000)
        let first = ToolchainSnapshot.recorded(previous: nil, now: inv(["Node": "22"]), at: t0)
        #expect(first.changes.isEmpty && first.changedAt == nil)
        let second = ToolchainSnapshot.recorded(previous: first, now: inv(["Node": "24"]), at: t1)
        #expect(second.changes == ["Node 22 -> 24"] && second.changedAt == t1)
        let third = ToolchainSnapshot.recorded(previous: second, now: inv(["Node": "24"]), at: t2)
        #expect(third.changes == second.changes && third.changedAt == t1 && third.at == t2)
    }

    @Test func unknownProbeKeepsThePreviousVersion() {
        let tools = Toolchains.resolve(["Node": .unknown, "Go": .absent, "Bun": .version("1.3.2"), "Ruby": .unknown],
                                       previous: ["Node": "22.1.0", "Go": "1.23.2"])
        #expect(tools == ["Node": "22.1.0", "Bun": "1.3.2"])
        #expect(Toolchains.changes(from: inv(["Node": "22.1.0", "Go": "1.23.2"]), to: inv(tools)) == ["Bun added (1.3.2)", "Go removed (was 1.23.2)"])
    }

    @Test func changesShowOnlyUntilAJobRunsAfterThem() {
        let t = { Date(timeIntervalSince1970: $0) }
        let s = ToolchainSnapshot(at: t(2000), inventory: inv(["Node": "24"]), changes: ["Node 22 -> 24"], changedAt: t(1000))
        #expect(Toolchains.visibleChanges(s, lastMacJob: nil) == ["Node 22 -> 24"])
        #expect(Toolchains.visibleChanges(s, lastMacJob: t(900)) == ["Node 22 -> 24"])
        #expect(Toolchains.visibleChanges(s, lastMacJob: t(1500)).isEmpty)
        #expect(Toolchains.visibleChanges(nil, lastMacJob: nil).isEmpty)
    }

    @Test func freshnessUsesTheNamedInterval() {
        let s = ToolchainSnapshot(at: Date(timeIntervalSince1970: 0), inventory: inv([:]), changes: [], changedAt: nil)
        #expect(s.isFresh(at: Date(timeIntervalSince1970: Toolchains.refreshSeconds - 1)))
        #expect(!s.isFresh(at: Date(timeIntervalSince1970: Toolchains.refreshSeconds + 1)))
    }

    @Test func xcodeMajorGivesLabel() {
        #expect(Toolchains.xcodeMajor(inv(["Xcode": "26.1"])) == "26")
        #expect(Toolchains.xcodeMajor(inv([:])) == nil)
    }

    @Test func snapshotRoundTripsThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolchains-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunnerStore(paths: NoodlePaths(root: root))
        #expect(store.toolchains() == nil)
        let s = ToolchainSnapshot(at: Date(timeIntervalSince1970: 5), inventory: inv(["Node": "22"]), changes: ["Node 20 -> 22"], changedAt: nil)
        try store.saveToolchains(s)
        #expect(store.toolchains() == s)
    }
}
