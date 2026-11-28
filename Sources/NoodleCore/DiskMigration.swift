import Darwin
import Foundation

/// Offline backup-and-migrate for legacy data disks that have no ext4 journal.
///
/// The original file is never opened for writing, truncated, renamed or replaced in content: it is read
/// once into a private sparse copy, the copy is compared byte for byte, then repaired and given a journal
/// with e2fsprogs. Only after the converted copy passes a read-only fsck is `data.img` pointed at it, and the
/// original inode stays reachable under a backup name (a hard link, so it costs no space).
public enum DiskMigration {
    public enum Kind: Equatable, Sendable { case missing, notExt4, journaled, legacy }

    public enum Stage: String, Sendable, CaseIterable {
        case copied, verified, converted, checked, backedUp, published
    }

    public struct Tools: Sendable {
        public var e2fsck: URL
        public var tune2fs: URL
        public init(e2fsck: URL, tune2fs: URL) { self.e2fsck = e2fsck; self.tune2fs = tune2fs }
        public init(resources: URL) {
            self.init(e2fsck: resources.appendingPathComponent("e2fsck"), tune2fs: resources.appendingPathComponent("tune2fs"))
        }
    }

    public struct Report: Sendable, Equatable {
        public var backup: URL
        public var copiedBytes: UInt64
        public var logicalBytes: UInt64
        public var repairedByFsck: Bool
    }

    public enum Outcome: Sendable, Equatable {
        case alreadyJournaled
        case dryRun(requiredBytes: UInt64, freeBytes: UInt64)
        case migrated(Report)
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Slack for the 16 MiB journal, fsck repairs and filesystem rounding.
    static let headroom: UInt64 = 80 << 20
    static let chunk = 1 << 20
    public static let backupName = "data.img.legacy-backup"

    // MARK: inspection

    public static func inspect(_ url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .notExt4 }
        defer { close(fd) }
        var sb = [UInt8](repeating: 0, count: 1024)
        guard pread(fd, &sb, 1024, 1024) == 1024 else { return .notExt4 }
        let magic = UInt16(sb[0x38]) | UInt16(sb[0x39]) << 8
        guard magic == 0xEF53 else { return .notExt4 }
        let compat = UInt32(sb[0x5C]) | UInt32(sb[0x5D]) << 8 | UInt32(sb[0x5E]) << 16 | UInt32(sb[0x5F]) << 24
        return compat & 0x4 != 0 ? .journaled : .legacy
    }

    /// The command to show a user whose disk was refused, including `NOODLE_HOME` when it is not the default.
    public static func command(forDisk disk: URL, executable: String? = nil) -> String {
        let root = disk.deletingLastPathComponent().standardizedFileURL.path
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".noodle").standardizedFileURL.path
        var exe = executable ?? "noodle"
        if executable == nil, let main = Bundle.main.executableURL {
            let sibling = main.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/noodle")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { exe = sibling.path }
        }
        let quoted = exe.contains(" ") || exe.contains("'") ? "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'" : exe
        let prefix = root == defaultRoot ? "" : "NOODLE_HOME='" + root.replacingOccurrences(of: "'", with: "'\\''") + "' "
        return prefix + quoted + " migrate-disk"
    }

    // MARK: migration

    /// Run the whole migration. `checkpoint` is called after each durable stage; tests throw from it to
    /// simulate a process that died there (no cleanup runs for `Interrupted`).
    public struct Interrupted: Error, Sendable { public init() {} }

    public static func migrate(root: URL, tools: Tools, dryRun: Bool = false,
                               progress: (String) -> Void = { _ in },
                               freeSpace: (URL) -> UInt64 = freeBytes,
                               checkpoint: (Stage) throws -> Void = { _ in }) throws -> Outcome {
        let source = root.appendingPathComponent("data.img")
        let staging = root.appendingPathComponent("data.img.migrating")
        switch inspect(source) {
        case .missing: throw Failure("no data disk at \(source.path); nothing to migrate")
        case .notExt4: throw Failure("\(source.path) is not a readable ext4 image; it was left untouched. Restore it from a backup instead")
        case .journaled:
            return .alreadyJournaled
        case .legacy: break
        }
        for tool in [tools.e2fsck, tools.tune2fs] {
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw Failure("migration tool is missing at \(tool.path); reinstall Noodle's resources")
            }
        }

        // Single owner: the daemon's own lock. A running daemon (or another migration) blocks us.
        let runDir = root.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        chmod(runDir.path, 0o700)
        let lockFD = open(runDir.appendingPathComponent("noodled.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            throw Failure("The Noodle engine (or another migration) is running for \(root.path). Stop it first with `noodle stop`, then retry")
        }
        defer { close(lockFD) }
        try requireNoOpener(source)

        var before = stat()
        guard lstat(source.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw Failure("\(source.path) is not a regular file; refusing to migrate it")
        }
        let logical = UInt64(before.st_size)
        let allocated = UInt64(before.st_blocks) * 512
        let required = allocated + headroom
        let free = freeSpace(root)
        guard free >= required else {
            throw Failure("not enough free space to migrate safely: need \(mib(required)) MiB (\(mib(allocated)) MiB data in the old disk + \(mib(headroom)) MiB working room) on the volume holding \(root.path), have \(mib(free)) MiB. Nothing was changed")
        }
        if dryRun { return .dryRun(requiredBytes: required, freeBytes: free) }

        // Stale private copy from a run that was killed. It is ours and never the only copy of anything.
        try? FileManager.default.removeItem(at: staging)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }
        do {
            progress("copying \(mib(allocated)) MiB of data (disk is \(mib(logical)) MiB, sparse)")
            let copied = try sparseCopy(from: source, to: staging, mode: before.st_mode & 0o777, progress: progress)
            try requireUnchanged(source, before)
            try checkpoint(.copied)

            progress("verifying the copy byte for byte")
            try verifyCopy(source: source, copy: staging)
            try requireUnchanged(source, before)
            try checkpoint(.verified)

            progress("repairing and adding a journal on the copy")
            var repaired = false
            // e2fsck -p may need more than one pass (clearing a stale orphan file leaves its inode bitmap bit for the next run).
            var clean = false
            for _ in 0..<4 {
                let pass = try runTool(tools.e2fsck, ["-f", "-p", staging.path])
                if pass.status == 0 { clean = true; break }
                guard pass.status == 1 || pass.status == 2 else {
                    throw Failure("the old disk has damage that automatic repair would not touch (e2fsck exit \(pass.status)). Your original is untouched. Output:\n\(pass.output)")
                }
                repaired = true
            }
            guard clean else { throw Failure("the copy still had errors after repeated automatic repair. Your original is untouched") }
            let tune = try runTool(tools.tune2fs, ["-j", "-J", "size=16", staging.path])
            guard tune.status == 0 else { throw Failure("could not add a journal to the copy (tune2fs exit \(tune.status)); your original is untouched. Output:\n\(tune.output)") }
            try checkpoint(.converted)

            progress("checking the migrated disk")
            let final = try runTool(tools.e2fsck, ["-f", "-n", staging.path])
            guard final.status == 0 else { throw Failure("the migrated copy failed its final check (e2fsck exit \(final.status)); your original is untouched. Output:\n\(final.output)") }
            guard inspect(staging) == .journaled else { throw Failure("the migrated copy still has no journal; your original is untouched") }
            try syncFile(staging)
            try checkpoint(.checked)

            // Publish. The original inode gets a second name first, so data.img is never missing and the
            // original is never modified; then one atomic rename switches data.img to the verified copy.
            try requireNoOpener(source)
            try requireUnchanged(source, before)
            let backup = try backupLinked(to: source, in: root) ?? makeBackupLink(of: source, in: root)
            try syncDirectory(root)
            try checkpoint(.backedUp)
            guard rename(staging.path, source.path) == 0 else {
                throw Failure("could not switch data.img to the migrated disk: \(String(cString: strerror(errno))). The original is intact")
            }
            succeeded = true
            try syncDirectory(root)
            try checkpoint(.published)
            return .migrated(Report(backup: backup, copiedBytes: copied, logicalBytes: logical, repairedByFsck: repaired))
        } catch let error as Interrupted {
            succeeded = true   // simulated crash: leave whatever a dead process would leave
            throw error
        }
    }
}
