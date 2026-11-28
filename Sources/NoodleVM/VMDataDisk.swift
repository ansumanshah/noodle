import Foundation
import OSLog
import NoodleCore

extension VMController {
    static func prepareDataDisk(_ url: URL, sizeBytes: UInt64) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard let superblock = Ext4Formatter.readSuperblock(at: url) else {
                throw VMError.invalidConfiguration("data disk at \(url.path) is not a readable ext4 image; preserve it and restore or repair it before starting Noodle")
            }
            guard superblock.compat & 0x4 != 0 else {
                throw VMError.invalidConfiguration("data disk at \(url.path) has no journal and cannot be safely started. It was not modified. Stop Noodle, then run `\(DiskMigration.command(forDisk: url))` to make a verified journaled copy (it keeps your original as \(DiskMigration.backupName))")
            }
            try Ext4Formatter.syncParentDirectory(of: url)
        } else if errno == ENOENT {
            let resources: URL
            if let value = ProcessInfo.processInfo.environment["NOODLE_RESOURCES"], !value.isEmpty {
                resources = URL(fileURLWithPath: value, isDirectory: true)
            } else if let bundleResources = Bundle.main.resourceURL {
                resources = bundleResources
            } else {
                throw VMError.invalidConfiguration("journaled disk formatter is unavailable; set NOODLE_RESOURCES or reinstall Noodle")
            }
            try Ext4Formatter.formatJournaled(at: url, sizeBytes: sizeBytes, tool: resources.appendingPathComponent("mke2fs"), config: resources.appendingPathComponent("mke2fs.conf"))
        } else {
            throw VMError.invalidConfiguration("cannot inspect data disk at \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
