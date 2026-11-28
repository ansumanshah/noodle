import Darwin
import Foundation

extension DiskMigration {
    /// Data ranges of an open file (holes skipped).
    static func dataRanges(_ fd: Int32, size: off_t) -> [Range<off_t>] {
        var out: [Range<off_t>] = []
        var pos: off_t = 0
        while pos < size {
            let start = lseek(fd, pos, SEEK_DATA)
            if start < 0 { break }
            var end = lseek(fd, start, SEEK_HOLE)
            if end < 0 || end > size { end = size }
            if end > start { out.append(start ..< end) }
            pos = end
        }
        return out
    }

    static func readFull(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int, at offset: off_t) throws -> Int {
        var done = 0
        while done < count {
            let n = pread(fd, buf + done, count - done, offset + off_t(done))
            if n < 0 { if errno == EINTR { continue }; throw Failure("read error: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            done += n
        }
        return done
    }

    static func isZero(_ buf: UnsafeRawBufferPointer) -> Bool {
        var i = 0
        let words = buf.count / 8
        let w = buf.bindMemory(to: UInt64.self)
        while i < words { if w[i] != 0 { return false }; i += 1 }
        var j = words * 8
        while j < buf.count { if buf[j] != 0 { return false }; j += 1 }
        return true
    }

    static func sparseCopy(from source: URL, to dest: URL, mode: mode_t, progress: (String) -> Void) throws -> UInt64 {
        let src = open(source.path, O_RDONLY | O_CLOEXEC)
        guard src >= 0 else { throw Failure("cannot read \(source.path): \(String(cString: strerror(errno)))") }
        defer { close(src) }
        var info = stat()
        fstat(src, &info)
        let dst = open(dest.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard dst >= 0 else { throw Failure("cannot create the working copy \(dest.path): \(String(cString: strerror(errno)))") }
        defer { close(dst) }
        guard ftruncate(dst, info.st_size) == 0 else { throw Failure("cannot size the working copy: \(String(cString: strerror(errno)))") }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }
        var written: UInt64 = 0
        let ranges = dataRanges(src, size: info.st_size)
        let total = ranges.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        var processed: UInt64 = 0
        var lastReport: UInt64 = 0
        for range in ranges {
            var off = range.lowerBound
            while off < range.upperBound {
                let want = Int(min(off_t(chunk), range.upperBound - off))
                let got = try readFull(src, buf, want, at: off)
                guard got == want else { throw Failure("\(source.path) is shorter than expected (it changed while copying). Nothing was replaced") }
                if !isZero(UnsafeRawBufferPointer(start: buf, count: want)) {
                    var done = 0
                    while done < want {
                        let n = pwrite(dst, buf + done, want - done, off + off_t(done))
                        if n < 0 { if errno == EINTR { continue }; throw Failure("cannot write the working copy: \(String(cString: strerror(errno))). Your original is untouched") }
                        done += n
                    }
                    written += UInt64(want)
                }
                off += off_t(want)
                processed += UInt64(want)
                if total > 0, processed - lastReport >= max(total / 10, 64 << 20) { lastReport = processed; progress("  copied \(processed * 100 / total)%") }
            }
        }
        guard fchmod(dst, mode) == 0, fsync(dst) == 0 else { throw Failure("cannot flush the working copy: \(String(cString: strerror(errno)))") }
        return written
    }

    /// Compare every data range of either file against the other, reading around the page cache.
    static func verifyCopy(source: URL, copy: URL) throws {
        let a = open(source.path, O_RDONLY | O_CLOEXEC), b = open(copy.path, O_RDONLY | O_CLOEXEC)
        guard a >= 0, b >= 0 else { if a >= 0 { close(a) }; if b >= 0 { close(b) }; throw Failure("cannot reopen files to verify the copy") }
        defer { close(a); close(b) }
        _ = fcntl(a, F_NOCACHE, 1); _ = fcntl(b, F_NOCACHE, 1)
        var sa = stat(), sb = stat()
        fstat(a, &sa); fstat(b, &sb)
        guard sa.st_size == sb.st_size else { throw Failure("the copy has a different size than the original; your original is untouched") }
        let x = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        let y = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { x.deallocate(); y.deallocate() }
        for ranges in [dataRanges(a, size: sa.st_size), dataRanges(b, size: sb.st_size)] {
            for range in ranges {
                var off = range.lowerBound
                while off < range.upperBound {
                    let want = Int(min(off_t(chunk), range.upperBound - off))
                    let g1 = try readFull(a, x, want, at: off), g2 = try readFull(b, y, want, at: off)
                    guard g1 == want, g2 == want, memcmp(x, y, want) == 0 else {
                        throw Failure("verification failed near byte \(off): the copy differs from the original. Your original is untouched")
                    }
                    off += off_t(want)
                }
            }
        }
    }
}
