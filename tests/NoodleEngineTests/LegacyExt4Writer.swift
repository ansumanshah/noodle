import Foundation
@testable import NoodleVM

/// Unjournaled ext4 writer for legacy-disk fixtures. Production creates disks with e2fsprogs.
extension Ext4Formatter {
    public struct Geometry: Sendable, Equatable {
        public var blockSize = 4096
        public var inodeSize = 256
        public var blocksCount: UInt64
        public var blocksPerGroup = 32768
        public var inodesPerGroup: Int
        public var groupCount: Int
        public var gdtBlocks: Int
        public var inodeTableBlocks: Int

        public init(sizeBytes: UInt64) throws {
            guard sizeBytes >= 8 << 20 else { throw Ext4Error.tooSmall }
            blocksCount = sizeBytes / 4096
            groupCount = Int((blocksCount + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup))
            // one inode per 16 KiB, rounded so the inode table fills whole blocks, bitmap fits one block.
            let inodesPerBlock = blockSize / inodeSize
            let groupBytes = min(UInt64(blocksPerGroup), blocksCount) * 4096
            var ipg = Int(groupBytes / 16384)
            ipg = max(inodesPerBlock * 2, ipg)
            ipg = (ipg + 7) / 8 * 8
            ipg = (ipg + inodesPerBlock - 1) / inodesPerBlock * inodesPerBlock
            ipg = min(ipg, 4096 * 8)
            inodesPerGroup = ipg
            inodeTableBlocks = ipg / inodesPerBlock
            gdtBlocks = (groupCount * 32 + 4095) / 4096
            // the last group must hold its own metadata plus something
            let lastBlocks = Int(blocksCount - UInt64(groupCount - 1) * UInt64(blocksPerGroup))
            if groupCount > 1 && lastBlocks < 2 + gdtBlocks + inodeTableBlocks + 50 {
                // drop the runt group; trailing space is simply unused
                groupCount -= 1
                blocksCount = UInt64(groupCount) * UInt64(blocksPerGroup)
                gdtBlocks = (groupCount * 32 + 4095) / 4096
            }
        }

        public func hasSuperBackup(_ g: Int) -> Bool {
            if g == 0 || g == 1 { return true }
            for base in [3, 5, 7] {
                var v = base
                while v < g { v *= base }
                if v == g { return true }
            }
            return false
        }

        public func groupStart(_ g: Int) -> UInt64 { UInt64(g) * UInt64(blocksPerGroup) }
        public func blocksInGroup(_ g: Int) -> Int {
            g == groupCount - 1 ? Int(blocksCount - groupStart(g)) : blocksPerGroup
        }
        /// Blocks occupied at the group start by the superblock copy and GDT.
        public func headerBlocks(_ g: Int) -> Int { hasSuperBackup(g) ? 1 + gdtBlocks : 0 }
        public func blockBitmap(_ g: Int) -> UInt64 { groupStart(g) + UInt64(headerBlocks(g)) }
        public func inodeBitmap(_ g: Int) -> UInt64 { blockBitmap(g) + 1 }
        public func inodeTable(_ g: Int) -> UInt64 { inodeBitmap(g) + 1 }
        public func firstFree(_ g: Int) -> UInt64 { inodeTable(g) + UInt64(inodeTableBlocks) }
    }

    static let lostFoundBlocks = 4

    /// Create an unjournaled legacy fixture; production disks use `formatJournaled`.
    @discardableResult
    public static func format(at url: URL, sizeBytes: UInt64, label: String = "noodle", uuid: UUID = UUID(), now: Date = Date(), exclusive: Bool = false) throws -> Geometry {
        let geo = try Geometry(sizeBytes: sizeBytes)
        let fd = open(url.path, O_RDWR | O_CREAT | (exclusive ? O_EXCL : O_TRUNC), 0o644)
        guard fd >= 0 else { throw Ext4Error.io("open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(geo.blocksCount * 4096)) == 0 else { throw Ext4Error.io("ftruncate: \(String(cString: strerror(errno)))") }

        func put(_ data: [UInt8], at offset: UInt64) throws {
            var written = 0
            while written < data.count {
                let n = data[written...].withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset) + off_t(written)) }
                guard n > 0 else { throw Ext4Error.io("pwrite: \(String(cString: strerror(errno)))") }
                written += n
            }
        }

        let ts = UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970))
        let bs = 4096

        // Directory blocks live in group 0 right after the inode table.
        let rootBlock = geo.firstFree(0)
        let lfBlock = rootBlock + 1       // lost+found uses lostFoundBlocks consecutive blocks
        let usedInGroup0Extra = 1 + lostFoundBlocks
        let rootIno: UInt32 = 2, lfIno: UInt32 = 11
        let reservedInodes = 11

        // ---- per group accounting
        var freeBlocks = [Int](repeating: 0, count: geo.groupCount)
        var freeInodes = [Int](repeating: geo.inodesPerGroup, count: geo.groupCount)
        var dirs = [Int](repeating: 0, count: geo.groupCount)
        for g in 0..<geo.groupCount {
            let meta = geo.headerBlocks(g) + 2 + geo.inodeTableBlocks + (g == 0 ? usedInGroup0Extra : 0)
            freeBlocks[g] = geo.blocksInGroup(g) - meta
            guard freeBlocks[g] > 0 else { throw Ext4Error.tooSmall }
        }
        freeInodes[0] -= reservedInodes
        dirs[0] = 2
        let totalFreeBlocks = freeBlocks.reduce(0, +)
        let totalFreeInodes = freeInodes.reduce(0, +)

        // ---- superblock
        func superblock(group: Int) -> [UInt8] {
            var sb = [UInt8](repeating: 0, count: 1024)
            func u32(_ off: Int, _ v: UInt32) { for i in 0..<4 { sb[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
            func u16(_ off: Int, _ v: UInt16) { sb[off] = UInt8(v & 0xff); sb[off + 1] = UInt8(v >> 8) }
            u32(0, UInt32(geo.inodesPerGroup * geo.groupCount))
            u32(4, UInt32(truncatingIfNeeded: geo.blocksCount))
            u32(8, UInt32(truncatingIfNeeded: geo.blocksCount / 100))
            u32(12, UInt32(totalFreeBlocks))
            u32(16, UInt32(totalFreeInodes))
            u32(20, 0)                                   // first data block (4K blocks)
            u32(24, 2); u32(28, 2)                       // log block size / cluster size
            u32(32, UInt32(geo.blocksPerGroup)); u32(36, UInt32(geo.blocksPerGroup))
            u32(40, UInt32(geo.inodesPerGroup))
            u32(44, 0); u32(48, ts)                      // mtime, wtime
            u16(52, 0); u16(54, 0xFFFF)                  // mnt count, max mnt count (-1)
            u16(56, magic); u16(58, 1); u16(60, 1)       // magic, state clean, errors=continue
            u32(64, ts); u32(68, 0); u32(72, 0)          // lastcheck, interval, creator os linux
            u32(76, 1)                                   // rev level 1 (dynamic)
            u32(84, 11); u16(88, UInt16(geo.inodeSize)); u16(90, UInt16(group))
            u32(92, 0x8 | 0x20)                          // compat: ext_attr, dir_index
            u32(96, 0x2 | 0x40)                          // incompat: filetype, extents
            u32(100, 0x1 | 0x2 | 0x20 | 0x40)            // ro_compat: sparse_super, large_file, dir_nlink, extra_isize
            let u = uuid.uuid
            let ub = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
            for i in 0..<16 { sb[104 + i] = ub[i] }
            for (i, c) in label.utf8.prefix(16).enumerated() { sb[120 + i] = c }
            u16(206, 0)                                  // reserved gdt blocks
            for i in 0..<16 { sb[236 + i] = ub[(i * 7 + 3) % 16] }   // hash seed
            sb[252] = 1                                  // def_hash_version: half_md4
            u16(254, 0)                                  // desc size (32-byte descriptors, no 64bit)
            u32(256, 0x0C)                               // default mount opts: user_xattr|acl
            u32(264, ts)                                 // mkfs time
            u16(348, 32); u16(350, 32)                   // min/want extra isize
            u32(352, 0x1)                                // flags: signed dirhash
            return sb
        }

        // ---- group descriptor table
        var gdt = [UInt8](repeating: 0, count: geo.gdtBlocks * bs)
        for g in 0..<geo.groupCount {
            let o = g * 32
            func u32(_ off: Int, _ v: UInt32) { for i in 0..<4 { gdt[o + off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
            func u16(_ off: Int, _ v: UInt16) { gdt[o + off] = UInt8(v & 0xff); gdt[o + off + 1] = UInt8(v >> 8) }
            u32(0, UInt32(geo.blockBitmap(g))); u32(4, UInt32(geo.inodeBitmap(g))); u32(8, UInt32(geo.inodeTable(g)))
            u16(12, UInt16(freeBlocks[g])); u16(14, UInt16(freeInodes[g])); u16(16, UInt16(dirs[g]))
        }

        // ---- write superblocks and GDTs (primary + backups)
        for g in 0..<geo.groupCount where geo.hasSuperBackup(g) {
            let start = geo.groupStart(g) * UInt64(bs)
            let sb = superblock(group: g)
            try put(sb, at: g == 0 ? start + 1024 : start)
            try put(gdt, at: start + UInt64(bs))
        }

        // ---- bitmaps
        for g in 0..<geo.groupCount {
            var bb = [UInt8](repeating: 0, count: bs)
            let used = geo.firstFree(g) - geo.groupStart(g) + (g == 0 ? UInt64(usedInGroup0Extra) : 0)
            for bit in 0..<Int(used) { bb[bit >> 3] |= 1 << UInt8(bit & 7) }
            // padding bits past the end of a short last group
            let inGroup = geo.blocksInGroup(g)
            if inGroup < bs * 8 { for bit in inGroup..<(bs * 8) { bb[bit >> 3] |= 1 << UInt8(bit & 7) } }
            try put(bb, at: geo.blockBitmap(g) * UInt64(bs))

            var ib = [UInt8](repeating: 0, count: bs)
            if g == 0 { for bit in 0..<reservedInodes { ib[bit >> 3] |= 1 << UInt8(bit & 7) } }
            for bit in geo.inodesPerGroup..<(bs * 8) { ib[bit >> 3] |= 1 << UInt8(bit & 7) }
            try put(ib, at: geo.inodeBitmap(g) * UInt64(bs))
        }

        // ---- inodes 2 (root) and 11 (lost+found), block-mapped directories
        func inode(mode: UInt16, links: UInt16, size: UInt32, blocks: [UInt64]) -> [UInt8] {
            var ino = [UInt8](repeating: 0, count: geo.inodeSize)
            func u32(_ off: Int, _ v: UInt32) { for i in 0..<4 { ino[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
            func u16(_ off: Int, _ v: UInt16) { ino[off] = UInt8(v & 0xff); ino[off + 1] = UInt8(v >> 8) }
            u16(0, mode); u32(4, size)
            u32(8, ts); u32(12, ts); u32(16, ts)
            u16(26, links)
            u32(28, UInt32(blocks.count * (bs / 512)))
            u32(32, 0)                                   // flags: no EXTENTS_FL -> block map
            for (i, b) in blocks.prefix(12).enumerated() { u32(40 + i * 4, UInt32(b)) }
            u16(128, 32)                                 // extra isize
            u32(144, ts)                                 // crtime (offset 144 in the extra area)
            return ino
        }
        let inodeBase = geo.inodeTable(0) * UInt64(bs)
        try put(inode(mode: 0o040755, links: 3, size: UInt32(bs), blocks: [rootBlock]), at: inodeBase + UInt64(Int(rootIno) - 1) * UInt64(geo.inodeSize))
        let lfBlocks = (0..<lostFoundBlocks).map { lfBlock + UInt64($0) }
        try put(inode(mode: 0o040700, links: 2, size: UInt32(bs * lostFoundBlocks), blocks: lfBlocks), at: inodeBase + UInt64(Int(lfIno) - 1) * UInt64(geo.inodeSize))

        // ---- directory blocks
        func dirent(_ ino: UInt32, _ name: String, type: UInt8, recLen: Int) -> [UInt8] {
            var e = [UInt8](repeating: 0, count: recLen)
            for i in 0..<4 { e[i] = UInt8((ino >> (8 * UInt32(i))) & 0xff) }
            e[4] = UInt8(recLen & 0xff); e[5] = UInt8(recLen >> 8)
            let nb = Array(name.utf8)
            e[6] = UInt8(nb.count); e[7] = type
            for (i, c) in nb.enumerated() { e[8 + i] = c }
            return e
        }
        var root = dirent(rootIno, ".", type: 2, recLen: 12)
        root += dirent(rootIno, "..", type: 2, recLen: 12)
        root += dirent(lfIno, "lost+found", type: 2, recLen: bs - 24)
        try put(root, at: rootBlock * UInt64(bs))
        var lf0 = dirent(lfIno, ".", type: 2, recLen: 12)
        lf0 += dirent(rootIno, "..", type: 2, recLen: bs - 12)
        try put(lf0, at: lfBlock * UInt64(bs))
        for i in 1..<lostFoundBlocks {
            try put(dirent(0, "", type: 0, recLen: bs), at: (lfBlock + UInt64(i)) * UInt64(bs))
        }

        guard fsync(fd) == 0 else { throw Ext4Error.io("fsync") }
        return geo
    }

    public struct GroupDescriptor: Sendable, Equatable {
        public var blockBitmap: UInt32, inodeBitmap: UInt32, inodeTable: UInt32
        public var freeBlocks: UInt16, freeInodes: UInt16, usedDirs: UInt16
    }

    /// Read the primary group descriptor table (32-byte descriptors, 4 KiB blocks).
    public static func readGroupDescriptors(at url: URL) -> [GroupDescriptor] {
        guard let sb = readSuperblock(at: url), sb.logBlockSize == 2, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let groups = Int((UInt64(sb.blocksCount) + UInt64(sb.blocksPerGroup) - 1) / UInt64(sb.blocksPerGroup))
        guard (try? h.seek(toOffset: 4096)) != nil, let d = try? h.read(upToCount: groups * 32), d.count == groups * 32 else { return [] }
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        return (0..<groups).map { g in
            let o = g * 32
            return GroupDescriptor(blockBitmap: u32(o), inodeBitmap: u32(o + 4), inodeTable: u32(o + 8),
                                   freeBlocks: u16(o + 12), freeInodes: u16(o + 14), usedDirs: u16(o + 16))
        }
    }

    /// Read one 4 KiB block.
    public static func readBlock(_ n: UInt64, from url: URL) -> [UInt8]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: n * 4096)) != nil, let d = try? h.read(upToCount: 4096), d.count == 4096 else { return nil }
        return [UInt8](d)
    }

    public static func isFormatted(_ url: URL) -> Bool { readSuperblock(at: url) != nil }
}
