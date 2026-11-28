import CryptoKit
import Foundation
import Testing
@testable import NoodleCore
import NoodleVM

/// Real legacy fixtures (no journal), real e2fsprogs. Needs build/resources/{mke2fs,e2fsck,tune2fs}.
@Suite(.serialized) struct DiskMigrationTests {
    static let resources: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/resources")
    static var tools: DiskMigration.Tools { .init(resources: resources) }

    func home() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-migrate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func sha(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 4 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A populated, non-journaled ext4 image built by upstream mke2fs; returns the random payload it holds.
    @discardableResult
    func populatedLegacy(at url: URL, mib: Int = 96) throws -> Data {
        let stage = url.deletingLastPathComponent().appendingPathComponent("stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("vol/a"), withIntermediateDirectories: true)
        var payload = Data(count: 3 << 20)
        payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try payload.write(to: stage.appendingPathComponent("vol/a/payload.bin"))
        try Data("hello legacy".utf8).write(to: stage.appendingPathComponent("vol/note.txt"))
        defer { try? FileManager.default.removeItem(at: stage) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url); try fh.truncate(atOffset: UInt64(mib) << 20); try fh.close()
        let r = try DiskMigration.runTool(Self.resources.appendingPathComponent("mke2fs"),
            ["-F", "-q", "-t", "ext4", "-b", "4096", "-O", "^has_journal", "-d", stage.path, url.path])
        #expect(r.status == 0, "\(r.output)")
        #expect(DiskMigration.inspect(url) == .legacy)
        return payload
    }

    func contains(_ image: URL, _ needle: Data) throws -> Bool {
        // Every 4 KiB block of the payload must exist as a block of the image (file blocks may be fragmented).
        let hay = try Data(contentsOf: image, options: .alwaysMapped)
        var blocks = Set<Data>()
        for off in stride(from: 0, to: hay.count, by: 4096) { blocks.insert(hay.subdata(in: off ..< off + 4096)) }
        return stride(from: 0, to: needle.count, by: 4096).allSatisfy { blocks.contains(needle.subdata(in: $0 ..< $0 + 4096)) }
    }

    func fsckClean(_ url: URL) throws {
        let r = try DiskMigration.runTool(Self.tools.e2fsck, ["-f", "-n", url.path])
        #expect(r.status == 0, "\(r.output)")
    }

    @Test func migratesPopulatedDiskAndKeepsOriginalIntact() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("data.img")
        let payload = try populatedLegacy(at: disk)
        let before = try sha(disk)
        let outcome = try DiskMigration.migrate(root: root, tools: Self.tools)
        guard case .migrated(let report) = outcome else { Issue.record("expected migrated, got \(outcome)"); return }
        #expect(report.backup.lastPathComponent == DiskMigration.backupName)
        #expect(try sha(report.backup) == before)                       // original bytes unchanged
        #expect(DiskMigration.inspect(report.backup) == .legacy)
        #expect(DiskMigration.inspect(disk) == .journaled)
        try fsckClean(disk)
        #expect(try contains(disk, payload))                            // data survived
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data.img.migrating").path))
        // second run is a no-op
        #expect(try DiskMigration.migrate(root: root, tools: Self.tools) == .alreadyJournaled)
        #expect(try sha(report.backup) == before)
    }

    @Test func migratesDiskMadeByTheOldSwiftFormatter() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("data.img")
        try Ext4Formatter.format(at: disk, sizeBytes: 256 << 20)
        let before = try sha(disk)
        guard case .migrated(let r) = try DiskMigration.migrate(root: root, tools: Self.tools) else { Issue.record("not migrated"); return }
        #expect(try sha(r.backup) == before)
        #expect(DiskMigration.inspect(disk) == .journaled)
        try fsckClean(disk)
    }

    @Test(arguments: DiskMigration.Stage.allCases)
    func interruptionAtEveryStageNeverHurtsTheOriginalAndRetrySucceeds(stage: DiskMigration.Stage) throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("data.img")
        let payload = try populatedLegacy(at: disk)
        let before = try sha(disk)
        #expect(throws: DiskMigration.Interrupted.self) {
            try DiskMigration.migrate(root: root, tools: Self.tools, checkpoint: { if $0 == stage { throw DiskMigration.Interrupted() } })
        }
        // Whatever a dead process left: the original bytes still exist under some name and data.img is a whole disk.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let originals = try names.filter { $0 != "run" }.filter { try sha(root.appendingPathComponent($0)) == before }
        #expect(!originals.isEmpty, "original lost after \(stage): \(names)")
        #expect(DiskMigration.inspect(disk) != .missing && DiskMigration.inspect(disk) != .notExt4)
        if stage != .published { #expect(try sha(disk) == before || stage == .published) }
        // Retry from the leftover state.
        let outcome = try DiskMigration.migrate(root: root, tools: Self.tools)
        if stage == .published { #expect(outcome == .alreadyJournaled) } else if case .migrated = outcome {} else { Issue.record("retry: \(outcome)") }
        #expect(DiskMigration.inspect(disk) == .journaled)
        try fsckClean(disk)
        #expect(try contains(disk, payload))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(DiskMigration.backupName) }
        #expect(backups.count == 1)                                     // no duplicate backups after retry
        #expect(try sha(root.appendingPathComponent(backups[0])) == before)
    }

    @Test func refusesWhenThereIsNotEnoughSpaceAndChangesNothing() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("data.img")
        try populatedLegacy(at: disk)
        let before = try sha(disk)
        #expect(throws: DiskMigration.Failure.self) {
            try DiskMigration.migrate(root: root, tools: Self.tools, freeSpace: { _ in 10 << 20 })
        }
        #expect(try sha(disk) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["data.img", "run"])
    }

    @Test func dryRunReportsNeedAndWritesNothing() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("data.img")
        try populatedLegacy(at: disk)
        guard case .dryRun(let need, let free) = try DiskMigration.migrate(root: root, tools: Self.tools, dryRun: true) else { Issue.record("not dry run"); return }
        #expect(need > 80 << 20 && free > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["data.img", "run"])
    }

    @Test func refusesGarbageAndMissingDisks() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: DiskMigration.Failure.self) { try DiskMigration.migrate(root: root, tools: Self.tools) }
        let disk = root.appendingPathComponent("data.img")
        try Data(repeating: 7, count: 1 << 20).write(to: disk)
        let before = try sha(disk)
        #expect(throws: DiskMigration.Failure.self) { try DiskMigration.migrate(root: root, tools: Self.tools) }
        #expect(try sha(disk) == before)
    }

    @Test func refusesWhileADaemonHoldsTheLock() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try populatedLegacy(at: root.appendingPathComponent("data.img"))
        let run = root.appendingPathComponent("run"); try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let fd = open(run.appendingPathComponent("noodled.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: DiskMigration.Failure.self) { try DiskMigration.migrate(root: root, tools: Self.tools) }
        #expect(DiskMigration.inspect(root.appendingPathComponent("data.img")) == .legacy)
    }

    @Test func refusalCommandNamesTheHomeWhenNotDefault() {
        let c = DiskMigration.command(forDisk: URL(fileURLWithPath: "/tmp/x y/data.img"), executable: "noodle")
        #expect(c == "NOODLE_HOME='/tmp/x y' noodle migrate-disk")
        let d = DiskMigration.command(forDisk: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".noodle/data.img"), executable: "noodle")
        #expect(d == "noodle migrate-disk")
    }
}
