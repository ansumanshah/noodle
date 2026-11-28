import Foundation
import Testing
@testable import NoodleVM
import NoodleCore

@Suite(.tags(.slow)) struct Ext4Tests {
    @Test func superblockIsCorrect() throws {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        let geo = try Ext4Formatter.format(at: url, sizeBytes: 512 << 20, label: "noodle")
        let sb = try #require(Ext4Formatter.readSuperblock(at: url))
        #expect(sb.magic == 0xEF53)
        #expect(sb.state == 1)
        #expect(sb.revLevel == 1)
        #expect(sb.logBlockSize == 2)                       // 4 KiB
        #expect(sb.blocksCount == 131072)
        #expect(sb.blocksPerGroup == 32768)
        #expect(sb.inodeSize == 256)
        #expect(sb.firstIno == 11)
        #expect(sb.inodesPerGroup == 8192)
        #expect(sb.inodesCount == 4 * 8192)
        #expect(sb.volumeName == "noodle")
        // incompat: filetype + extents, no journal, no 64bit, no flex_bg
        #expect(sb.incompat == 0x42)
        #expect(sb.compat & 0x4 == 0)                       // has_journal off
        #expect(sb.roCompat & 0x1 != 0)                     // sparse_super
        #expect(sb.roCompat & 0x400 == 0)                   // metadata_csum off
        #expect(geo.groupCount == 4)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        #expect(size.uint64Value == 512 << 20)
    }

    @Test func imageIsSparse() throws {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        try Ext4Formatter.format(at: url, sizeBytes: 4 << 30)
        var st = stat()
        #expect(stat(url.path, &st) == 0)
        let allocated = Int64(st.st_blocks) * 512
        #expect(allocated < 16 << 20)                       // a 4 GiB disk costs a few MiB
    }

    @Test func freeCountsMatchBitmaps() throws {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        try Ext4Formatter.format(at: url, sizeBytes: 640 << 20)       // 5 groups, sparse_super backups on 0,1,3
        let sb = try #require(Ext4Formatter.readSuperblock(at: url))
        let gds = Ext4Formatter.readGroupDescriptors(at: url)
        #expect(gds.count == 5)
        var totalFreeBlocks: UInt32 = 0, totalFreeInodes: UInt32 = 0
        for (g, gd) in gds.enumerated() {
            let bb = try #require(Ext4Formatter.readBlock(UInt64(gd.blockBitmap), from: url))
            var used = 0
            for bit in 0..<32768 where bb[bit >> 3] & (1 << UInt8(bit & 7)) != 0 { used += 1 }
            #expect(32768 - used == Int(gd.freeBlocks), "group \(g) free blocks")
            // the group's own metadata is marked used
            let rel = Int(gd.blockBitmap) - g * 32768
            #expect(bb[rel >> 3] & (1 << UInt8(rel & 7)) != 0)
            let ib = try #require(Ext4Formatter.readBlock(UInt64(gd.inodeBitmap), from: url))
            var usedInodes = 0
            for bit in 0..<Int(sb.inodesPerGroup) where ib[bit >> 3] & (1 << UInt8(bit & 7)) != 0 { usedInodes += 1 }
            #expect(Int(sb.inodesPerGroup) - usedInodes == Int(gd.freeInodes), "group \(g) free inodes")
            // padding bits after the last inode are set
            #expect(ib[Int(sb.inodesPerGroup) / 8] == 0xff)
            totalFreeBlocks += UInt32(gd.freeBlocks); totalFreeInodes += UInt32(gd.freeInodes)
        }
        #expect(totalFreeBlocks == sb.freeBlocks)
        #expect(totalFreeInodes == sb.freeInodes)
        #expect(gds[0].usedDirs == 2)                        // root + lost+found
        #expect(gds[0].freeInodes == 8192 - 11)
        // backup superblocks exist in groups 1 and 3 and carry the right group number
        for g in [1, 3] {
            let blk = try #require(Ext4Formatter.readBlock(UInt64(g) * 32768, from: url))
            #expect(blk[56] == 0x53 && blk[57] == 0xEF)
            #expect(blk[90] == UInt8(g))
        }
        // and not in group 2
        let none = try #require(Ext4Formatter.readBlock(2 * 32768, from: url))
        #expect(!(none[56] == 0x53 && none[57] == 0xEF))
    }

    @Test func rootDirectoryIsReadable() throws {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        try Ext4Formatter.format(at: url, sizeBytes: 128 << 20)
        let gd = try #require(Ext4Formatter.readGroupDescriptors(at: url).first)
        // inode 2 sits at index 1 in the first inode table block
        let tbl = try #require(Ext4Formatter.readBlock(UInt64(gd.inodeTable), from: url))
        let ino = Array(tbl[256..<512])
        let mode = UInt16(ino[0]) | UInt16(ino[1]) << 8
        #expect(mode == 0o040755)
        let links = UInt16(ino[26]) | UInt16(ino[27]) << 8
        #expect(links == 3)
        let flags = UInt32(ino[32]) | UInt32(ino[33]) << 8
        #expect(flags == 0)                                  // block map, no EXTENTS_FL
        let dirBlock = UInt64(ino[40]) | UInt64(ino[41]) << 8 | UInt64(ino[42]) << 16 | UInt64(ino[43]) << 24
        let dir = try #require(Ext4Formatter.readBlock(dirBlock, from: url))
        // ".", "..", "lost+found" with filetype set, rec_len chain ends at the block end
        var off = 0; var names: [String] = []
        while off < 4096 {
            let inum = UInt32(dir[off]) | UInt32(dir[off + 1]) << 8 | UInt32(dir[off + 2]) << 16 | UInt32(dir[off + 3]) << 24
            let recLen = Int(dir[off + 4]) | Int(dir[off + 5]) << 8
            let nameLen = Int(dir[off + 6])
            #expect(dir[off + 7] == 2)                       // EXT4_FT_DIR
            names.append(String(decoding: dir[(off + 8)..<(off + 8 + nameLen)], as: UTF8.self))
            #expect(inum != 0)
            off += recLen
        }
        #expect(off == 4096)
        #expect(names == [".", "..", "lost+found"])
    }

    @Test func tooSmallIsRejected() {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: Ext4Formatter.Ext4Error.self) { try Ext4Formatter.format(at: url, sizeBytes: 1 << 20) }
    }

    @Test func isFormattedDetection() throws {
        let url = scratchPath("ext4"); defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 4096 * 4))
        #expect(!Ext4Formatter.isFormatted(url))
        try Ext4Formatter.format(at: url, sizeBytes: 64 << 20)
        #expect(Ext4Formatter.isFormatted(url))
    }

    /// Geometry must match what e2fsprogs produces for the same options. Skipped when mke2fs is not installed.
    @Test func matchesMke2fsGeometry() throws {
        let candidates = [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/mke2fs", "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs", "/usr/local/sbin/mke2fs"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let ref = scratchPath("ext4"), mine = scratchPath("ext4")
        defer { try? FileManager.default.removeItem(at: ref); try? FileManager.default.removeItem(at: mine) }
        let size = 512 << 20
        FileManager.default.createFile(atPath: ref.path, contents: nil)
        let fh = try FileHandle(forWritingTo: ref); try fh.truncate(atOffset: UInt64(size)); try fh.close()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-q", "-t", "ext4", "-b", "4096", "-I", "256", "-O", "^has_journal,^resize_inode,^flex_bg,^metadata_csum,^64bit,^uninit_bg,^huge_file",
                       "-E", "lazy_itable_init=1,nodiscard", "-F", ref.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        try Ext4Formatter.format(at: mine, sizeBytes: UInt64(size))

        let a = try #require(Ext4Formatter.readSuperblock(at: ref)), b = try #require(Ext4Formatter.readSuperblock(at: mine))
        #expect(a.blocksCount == b.blocksCount)
        #expect(a.blocksPerGroup == b.blocksPerGroup)
        #expect(a.inodesPerGroup == b.inodesPerGroup)
        #expect(a.inodesCount == b.inodesCount)
        #expect(a.inodeSize == b.inodeSize)
        #expect(a.firstIno == b.firstIno)
        #expect(a.incompat == b.incompat)
        let ga = Ext4Formatter.readGroupDescriptors(at: ref), gb = Ext4Formatter.readGroupDescriptors(at: mine)
        #expect(ga.count == gb.count)
        for (x, y) in zip(ga, gb) {
            #expect(x.blockBitmap == y.blockBitmap)
            #expect(x.inodeBitmap == y.inodeBitmap)
            #expect(x.inodeTable == y.inodeTable)
            #expect(x.freeBlocks == y.freeBlocks)
            #expect(x.freeInodes == y.freeInodes)
            #expect(x.usedDirs == y.usedDirs)
        }
        #expect(a.freeBlocks == b.freeBlocks)
        #expect(a.freeInodes == b.freeInodes)
    }
}

@Suite struct VMConfigurationTests {
    @Test func missingDiskDirectoryCannotBeSynced() {
        let disk = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-missing-" + UUID().uuidString).appendingPathComponent("data.img")
        #expect(throws: Ext4Formatter.Ext4Error.self) { try Ext4Formatter.syncParentDirectory(of: disk) }
    }

    @Test func existingUnknownDiskIsNeverFormatted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disk-safety-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appendingPathComponent("data.img")
        let original = Data("not an ext4 disk".utf8)
        try original.write(to: disk)
        #expect(throws: VMError.self) { try VMController.prepareDataDisk(disk, sizeBytes: 64 << 20) }
        #expect(try Data(contentsOf: disk) == original)
        #expect(throws: Ext4Formatter.Ext4Error.self) { try Ext4Formatter.format(at: disk, sizeBytes: 64 << 20, exclusive: true) }
        #expect(try Data(contentsOf: disk) == original)
    }

    @Test func freshDiskIsFormattedWithoutReplacingExistingDisk() throws {
        guard let resources = ProcessInfo.processInfo.environment["NOODLE_RESOURCES"],
              FileManager.default.isExecutableFile(atPath: resources + "/mke2fs") else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disk-fresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appendingPathComponent("data.img")
        try VMController.prepareDataDisk(disk, sizeBytes: 64 << 20)
        #expect(try #require(Ext4Formatter.readSuperblock(at: disk)).compat & 0x4 != 0)
        let before = try Data(contentsOf: disk, options: .mappedIfSafe).prefix(4096)
        try VMController.prepareDataDisk(disk, sizeBytes: 128 << 20)
        #expect(try Data(contentsOf: disk, options: .mappedIfSafe).prefix(4096) == before)
    }

    @Test func legacyDiskIsPreservedAndRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("disk-legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appendingPathComponent("data.img")
        try Ext4Formatter.format(at: disk, sizeBytes: 64 << 20)
        let before = try Data(contentsOf: disk, options: .mappedIfSafe).prefix(4096)
        #expect(throws: VMError.self) { try VMController.prepareDataDisk(disk, sizeBytes: 64 << 20) }
        #expect(try Data(contentsOf: disk, options: .mappedIfSafe).prefix(4096) == before)
    }

    @Test func journaledDefaultDiskRemainsSparse() throws {
        guard let resources = ProcessInfo.processInfo.environment["NOODLE_RESOURCES"],
              FileManager.default.isExecutableFile(atPath: resources + "/mke2fs") else { return }
        let disk = FileManager.default.temporaryDirectory.appendingPathComponent("disk-sparse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: disk) }
        let directory = URL(fileURLWithPath: resources, isDirectory: true)
        try Ext4Formatter.formatJournaled(at: disk, sizeBytes: 64 << 30,
                                         tool: directory.appendingPathComponent("mke2fs"),
                                         config: directory.appendingPathComponent("mke2fs.conf"))
        var info = stat()
        #expect(lstat(disk.path, &info) == 0)
        #expect(info.st_size == 64 << 30)
        #expect(info.st_blocks * 512 < 64 << 20)
        #expect(try #require(Ext4Formatter.readSuperblock(at: disk)).compat & 0x4 != 0)
        #expect(throws: Ext4Formatter.Ext4Error.self) {
            try Ext4Formatter.formatJournaled(at: disk, sizeBytes: 64 << 20,
                                             tool: directory.appendingPathComponent("mke2fs"),
                                             config: directory.appendingPathComponent("mke2fs.conf"))
        }
        #expect(lstat(disk.path, &info) == 0 && info.st_size == 64 << 30)
    }
    /// The Virtualization configuration (devices, shares, balloon, vsock) must validate with placeholder boot files.
    @Test func configurationValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmcfg-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = NoodlePaths(root: dir)
        try paths.ensureDirectories()
        FileManager.default.createFile(atPath: paths.kernel.path, contents: Data(count: 4096))
        FileManager.default.createFile(atPath: paths.initramfs.path, contents: Data(count: 4096))
        try Ext4Formatter.format(at: paths.dataDisk, sizeBytes: 64 << 20)
        let cfg = VMBootConfiguration(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))
        let host = VirtualMachineHost(configuration: cfg) { _ in }
        do { try host.validateConfiguration() }
        catch VMError.invalidConfiguration(let why) where why.contains("entitlement") { return }   // unsigned test runner: build-only coverage
        #expect(FileManager.default.fileExists(atPath: paths.vmLog.path))
    }

    @Test func missingAssetsAreReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmcfg-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = NoodlePaths(root: dir)
        try paths.ensureDirectories()
        let host = VirtualMachineHost(configuration: VMBootConfiguration(paths: paths, settings: VMSettings(cpus: 2, memoryMiB: 1024))) { _ in }
        #expect(throws: VMError.self) { try host.validateConfiguration() }
    }
}
