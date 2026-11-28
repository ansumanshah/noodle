import Foundation
import NoodleCore

/// Creates journaled guest disks with e2fsprogs and reads the superblock. The unjournaled test writer lives in the test target.
public enum Ext4Formatter {
    public enum Ext4Error: Error { case tooSmall, io(String) }

    /// Create a new journaled disk with the bundled e2fsprogs formatter. Never replaces an existing path.
    public static func formatJournaled(at url: URL, sizeBytes: UInt64, tool: URL, config: URL) throws {
        guard sizeBytes >= 64 << 20 else { throw Ext4Error.tooSmall }
        guard FileManager.default.isExecutableFile(atPath: tool.path), FileManager.default.isReadableFile(atPath: config.path) else {
            throw Ext4Error.io("journaled disk formatter is unavailable at \(tool.path); reinstall Noodle's resources")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).creating-\(UUID().uuidString)")
        let fd = open(temporary.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Ext4Error.io("cannot create data disk at \(url.path): \(String(cString: strerror(errno)))") }
        defer { _ = unlink(temporary.path) }
        let resized = ftruncate(fd, off_t(sizeBytes))
        close(fd)
        guard resized == 0 else { throw Ext4Error.io("cannot size new data disk at \(url.path)") }
        var environment = ProcessInfo.processInfo.environment
        environment["MKE2FS_CONFIG"] = config.path
        let status: Int32, message: String
        do {
            (status, message) = try runCapturing(tool, ["-F", "-q", "-t", "ext4", "-b", "4096", "-J", "size=16", "-E", "nodiscard,lazy_itable_init=1,lazy_journal_init=0", temporary.path], environment: environment)
        } catch { throw Ext4Error.io("could not start disk formatter: \(error)") }
        guard status == 0, let sb = readSuperblock(at: temporary), sb.compat & 0x4 != 0 else {
            throw Ext4Error.io("could not format new data disk at \(url.path): \(message)")
        }
        let formatted = open(temporary.path, O_RDONLY)
        guard formatted >= 0 else { throw Ext4Error.io("could not open formatted data disk at \(temporary.path)") }
        let synced = fsync(formatted)
        close(formatted)
        guard synced == 0 else { throw Ext4Error.io("could not sync formatted data disk at \(temporary.path)") }
        guard link(temporary.path, url.path) == 0 else {
            throw Ext4Error.io("could not publish new data disk at \(url.path): \(String(cString: strerror(errno)))")
        }
        try syncParentDirectory(of: url)
    }

    static func syncParentDirectory(of url: URL) throws {
        let path = url.deletingLastPathComponent().path
        let directory = open(path, O_RDONLY)
        guard directory >= 0 else { throw Ext4Error.io("cannot open data disk directory at \(path): \(String(cString: strerror(errno)))") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw Ext4Error.io("cannot sync data disk directory at \(path): \(String(cString: strerror(errno)))") }
    }

    public static let magic: UInt16 = 0xEF53

    // MARK: - Inspection (used by tests and by the VM to decide whether a disk needs formatting)

    public struct Superblock: Sendable, Equatable {
        public var inodesCount: UInt32, blocksCount: UInt32, freeBlocks: UInt32, freeInodes: UInt32
        public var blocksPerGroup: UInt32, inodesPerGroup: UInt32
        public var logBlockSize: UInt32, magic: UInt16, state: UInt16, revLevel: UInt32
        public var inodeSize: UInt16, compat: UInt32, incompat: UInt32, roCompat: UInt32
        public var firstIno: UInt32, volumeName: String
    }

    public static func readSuperblock(at url: URL) -> Superblock? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: 1024)) != nil, let d = try? h.read(upToCount: 1024), d.count == 1024 else { return nil }
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        let sb = Superblock(inodesCount: u32(0), blocksCount: u32(4), freeBlocks: u32(12), freeInodes: u32(16),
                            blocksPerGroup: u32(32), inodesPerGroup: u32(40), logBlockSize: u32(24), magic: u16(56),
                            state: u16(58), revLevel: u32(76), inodeSize: u16(88), compat: u32(92), incompat: u32(96),
                            roCompat: u32(100), firstIno: u32(84),
                            volumeName: String(decoding: b[120..<136].prefix { $0 != 0 }, as: UTF8.self))
        return sb.magic == magic ? sb : nil
    }
}
