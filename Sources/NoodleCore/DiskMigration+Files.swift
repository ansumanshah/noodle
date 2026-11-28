import Darwin
import Foundation

extension DiskMigration {
    // MARK: pieces

    /// An existing backup name that is the same inode as `source` (left by an interrupted run).
    static func backupLinked(to source: URL, in root: URL) -> URL? {
        var s = stat()
        guard lstat(source.path, &s) == 0 else { return nil }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(backupName) {
            var b = stat()
            if lstat(root.appendingPathComponent(name).path, &b) == 0, b.st_ino == s.st_ino, b.st_dev == s.st_dev {
                return root.appendingPathComponent(name)
            }
        }
        return nil
    }

    static func makeBackupLink(of source: URL, in root: URL) throws -> URL {
        var n = 1
        while true {
            let url = root.appendingPathComponent(n == 1 ? backupName : "\(backupName)-\(n)")
            if link(source.path, url.path) == 0 { return url }
            guard errno == EEXIST else { throw Failure("cannot keep the original as \(url.path): \(String(cString: strerror(errno))). Nothing was changed") }
            n += 1
        }
    }

    static func requireNoOpener(_ file: URL) throws {
        var pids = [Int32](repeating: 0, count: 64)
        let n = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file.path, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        let others = n > 0 ? pids.prefix(Int(n) / MemoryLayout<Int32>.size).filter { $0 != 0 && $0 != me } : []
        if let pid = others.first {
            throw Failure("process \(pid) still has \(file.path) open (a VM process left after the engine stopped?). Wait for it to exit or stop it, then retry. Nothing was changed")
        }
    }

    static func requireUnchanged(_ url: URL, _ old: stat) throws {
        var now = stat()
        guard lstat(url.path, &now) == 0, now.st_ino == old.st_ino, now.st_size == old.st_size,
              now.st_mtimespec.tv_sec == old.st_mtimespec.tv_sec, now.st_mtimespec.tv_nsec == old.st_mtimespec.tv_nsec else {
            throw Failure("\(url.path) changed while it was being migrated; something is still using it. Nothing was replaced")
        }
    }

    public static func freeBytes(at url: URL) -> UInt64 {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return 0 }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    public static func mib(_ bytes: UInt64) -> UInt64 { (bytes + (1 << 20) - 1) >> 20 }
    static func runTool(_ tool: URL, _ args: [String]) throws -> (status: Int32, output: String) {
        do {
            let (status, output) = try runCapturing(tool, args, environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "E2FSCK_CONFIG": "/dev/null", "MKE2FS_CONFIG": "/dev/null"])
            return (status, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { throw Failure("could not start \(tool.lastPathComponent): \(error)") }
    }

    static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("cannot open \(url.path) to flush it") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure("cannot flush \(url.path): \(String(cString: strerror(errno)))") }
    }

    static func syncDirectory(_ url: URL) throws { try syncFile(url) }
}
