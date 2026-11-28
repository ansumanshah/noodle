import Foundation
import Testing
@testable import NoodleCore

@Suite struct UpdateTransactionTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-transaction-\(UUID())")
        var paths: NoodlePaths { NoodlePaths(root: root.appendingPathComponent("home")) }
        var target: URL { root.appendingPathComponent("Applications/Noodle.app") }
        var staged: URL { root.appendingPathComponent("staged/Noodle.app") }

        init() throws {
            try app(target, build: 1)
            try app(staged, build: 2)
            try UpdateStore.save(UpdateState(phase: .staged, version: "2", build: 2, stagedApp: staged.path), paths)
        }

        func app(_ url: URL, build: Int) throws {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let macos = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Noodle"))
            let plist: [String: Any] = ["CFBundleVersion": String(build), "CFBundleExecutable": "Noodle", "CFBundleIdentifier": "dev.getnoodle.Noodle"]
            try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", url.path])
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func installRejectsAStagedBundleTamperedAfterStaging() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try Data("x".utf8).write(to: f.staged.appendingPathComponent("Contents/MacOS/Noodle"))
        #expect(throws: UpdateError.self) { try UpdateInstaller.install(target: f.target, paths: f.paths) }
    }

    @Test func commitFailureRestoresTheOldBundleEvenWhenStateRemainsUnwritable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var journalSaved = false
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.install(target: f.target, paths: f.paths) { state, paths in
                if journalSaved {
                    // Fail the commit after the new bundle really reached its target, and any
                    // attempt to reset state afterwards, as with a full disk.
                    if state.phase == .installed { #expect(UpdateInstaller.build(of: f.target) == 2) }
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                #expect(state.phase == .installing)
                #expect(UpdateInstaller.build(of: f.target) == 1)
                try UpdateStore.save(state, paths)
                journalSaved = true
            }
        }
        #expect(journalSaved)
        #expect(UpdateInstaller.build(of: f.target) == 1)
        #expect(UpdateStore.load(f.paths)?.phase == .installing)
        #expect(!UpdateInstaller.launchCheck(paths: f.paths))
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
    }

    @Test func journalFailureNeverReplacesTheTarget() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.install(target: f.target, paths: f.paths) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        }
        #expect(UpdateInstaller.build(of: f.target) == 1)
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.target.deletingLastPathComponent().path) == ["Noodle.app"])
    }

    @Test(arguments: [false, true])
    func launchRecoversAnInterruptedSwap(swapped: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let sibling = f.target.deletingLastPathComponent().appendingPathComponent(".Noodle-new.app")
        try FileManager.default.copyItem(at: swapped ? f.target : f.staged, to: sibling)
        if swapped {
            try FileManager.default.removeItem(at: f.target)
            try FileManager.default.copyItem(at: f.staged, to: f.target)
        }
        var state = try #require(UpdateStore.load(f.paths))
        state.phase = .installing; state.target = f.target.path; state.transactionApp = sibling.path
        try UpdateStore.save(state, f.paths)
        #expect(UpdateInstaller.launchCheck(paths: f.paths) == swapped)
        #expect(UpdateInstaller.build(of: f.target) == 1)
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
        #expect(!FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test(arguments: [2, 3])
    func installRejectsSameOrNewerTarget(build: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.app(f.target, build: build)
        #expect(throws: UpdateError.notNewer) { try UpdateInstaller.install(target: f.target, paths: f.paths) }
        #expect(UpdateInstaller.build(of: f.target) == build)
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
    }

    @Test func installRejectsUnreadableTargetBuild() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.target.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: UpdateError.self) { try UpdateInstaller.install(target: f.target, paths: f.paths) }
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
    }

    @Test(arguments: [2, 3])
    func preflightRejectsSameOrNewerTargetWithoutChangingState(build: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.app(f.target, build: build)
        let state = UpdateStore.load(f.paths)
        #expect(throws: UpdateError.notNewer) { try UpdateInstaller.preflightInstall(target: f.target, paths: f.paths) }
        #expect(UpdateStore.load(f.paths) == state)
        #expect(UpdateInstaller.build(of: f.target) == build)
    }

    @Test func preflightRejectsMissingStagedBundle() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.staged)
        #expect(throws: UpdateError.noStagedUpdate) { try UpdateInstaller.preflightInstall(target: f.target, paths: f.paths) }
        #expect(UpdateInstaller.build(of: f.target) == 1)
    }

    @Test func installRechecksEligibilityAfterPreflight() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try UpdateInstaller.preflightInstall(target: f.target, paths: f.paths)
        try f.app(f.target, build: 3)
        #expect(throws: UpdateError.notNewer) { try UpdateInstaller.install(target: f.target, paths: f.paths) }
        #expect(UpdateInstaller.build(of: f.target) == 3)
    }

    @Test(arguments: [false, true])
    func launchOnlyRequestsRelaunchForCompletedRecoveryWhenJournalResetFails(swapped: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let partner = f.target.deletingLastPathComponent().appendingPathComponent(".Noodle-new.app")
        try FileManager.default.copyItem(at: swapped ? f.target : f.staged, to: partner)
        if swapped {
            try FileManager.default.removeItem(at: f.target)
            try FileManager.default.copyItem(at: f.staged, to: f.target)
        }
        var state = try #require(UpdateStore.load(f.paths))
        state.phase = .installing; state.target = f.target.path; state.transactionApp = partner.path
        try UpdateStore.save(state, f.paths)
        let directory = UpdateStore.dir(f.paths).path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
        #expect(UpdateInstaller.launchCheck(paths: f.paths) == swapped)
        #expect(UpdateInstaller.build(of: f.target) == 1)
        #expect(UpdateStore.load(f.paths)?.phase == .installing)
        #expect(FileManager.default.fileExists(atPath: partner.path))
        #expect(!UpdateInstaller.launchCheck(paths: f.paths))
        #expect(UpdateInstaller.build(of: f.target) == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        #expect(!UpdateInstaller.launchCheck(paths: f.paths))
        #expect(UpdateStore.load(f.paths)?.phase == .staged)
        #expect(!FileManager.default.fileExists(atPath: partner.path))
    }

    @Test func rollbackPreflightUsesTheRecordedTargetAndDoesNotSwap() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try UpdateInstaller.install(target: f.target, paths: f.paths)
        #expect(try UpdateInstaller.preflightRollback(paths: f.paths) == f.target)
        #expect(UpdateInstaller.build(of: f.target) == 2)
        try UpdateInstaller.rollback(paths: f.paths)
        #expect(UpdateInstaller.build(of: f.target) == 1)
    }

    @Test func rollbackPreflightRejectsMissingBackupWithoutChangingTheApp() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try UpdateInstaller.install(target: f.target, paths: f.paths)
        try FileManager.default.removeItem(at: UpdateStore.previous(f.paths))
        #expect(throws: UpdateError.noStagedUpdate) { try UpdateInstaller.preflightRollback(paths: f.paths) }
        #expect(UpdateInstaller.build(of: f.target) == 2)
        #expect(UpdateStore.load(f.paths)?.phase == .installed)
    }

    @Test func rollbackCanRestoreWhenTheInstalledBuildIsUnreadable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try UpdateInstaller.install(target: f.target, paths: f.paths)
        try FileManager.default.removeItem(at: f.target.appendingPathComponent("Contents/Info.plist"))
        #expect(try UpdateInstaller.preflightRollback(paths: f.paths) == f.target)
        try UpdateInstaller.rollback(paths: f.paths)
        #expect(UpdateInstaller.build(of: f.target) == 1)
    }
}
