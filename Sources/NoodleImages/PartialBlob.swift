import Foundation
import Darwin
import NoodleCore

/// A blob download in progress. The bytes land in `root/partial/<hex>.part`, which survives an interrupted pull so the
/// next one can ask the registry for the rest. The file is never a blob until its whole content hashes to the digest.
///
/// One puller owns a partial at a time (an exclusive `flock`). A second puller of the same blob gets a private scratch
/// file instead, so two pulls can never write into the same bytes.
public final class PartialBlob: @unchecked Sendable {
    public let url: URL
    /// True when this is the shared, resumable file; false for a private scratch file that is deleted on close.
    public let isShared: Bool
    private var fd: Int32
    private var consumed = false
    private var hasher = Digest.Hasher()
    /// Bytes in the file, which are also the bytes fed to the hasher.
    public private(set) var size: Int64 = 0

    fileprivate init(url: URL, fd: Int32, isShared: Bool) {
        self.url = url; self.fd = fd; self.isShared = isShared
    }

    /// Rebuild the hash state from bytes already on disk, one reused 1 MB buffer at a time.
    func rehash() throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ImageError.io("stat partial blob: \(String(cString: strerror(errno)))") }
        hasher = Digest.Hasher(); size = 0
        let chunk = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        var offset: off_t = 0
        while offset < st.st_size {
            let n = pread(fd, buf, chunk, offset)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buf, count: n))
            offset += off_t(n)
        }
        size = Int64(offset)
        if offset != st.st_size { try reset() }
    }

    func append(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(size) + off_t(done))
                if n < 0, errno == EINTR { continue }
                if n <= 0 { throw ImageError.io("write partial blob: \(String(cString: strerror(errno)))") }
                done += n
            }
            hasher.update(raw)
        }
        size += Int64(data.count)
    }

    /// Throw the bytes away and start the blob over.
    func reset() throws {
        guard ftruncate(fd, 0) == 0 else { throw ImageError.io("truncate partial blob: \(String(cString: strerror(errno)))") }
        hasher = Digest.Hasher(); size = 0
    }

    /// Digest of everything in the file so far.
    func currentDigest() -> String {
        var copy = hasher
        return copy.finalize()
    }

    /// Make the file a blob. Only call after `currentDigest()` equals `digest`.
    func promote(into store: BlobStore, as digest: String) throws {
        guard fsync(fd) == 0 else { throw ImageError.io("sync partial blob: \(String(cString: strerror(errno)))") }
        try store.install(url, as: digest)
        consumed = true
    }

    /// Delete the file (corrupt or unwanted bytes).
    func discard() {
        guard !consumed else { return }   // a promoted file is the blob now; never truncate it
        try? reset()
        unlink(url.path)
        consumed = true
    }

    /// Release the lock. A shared partial stays for the next try; a private one goes.
    func close() {
        guard fd >= 0 else { return }
        if !isShared && !consumed { unlink(url.path) }
        Darwin.close(fd); fd = -1
    }

    deinit { close() }
}

extension BlobStore {
    public var partialDir: URL { paths.root.appendingPathComponent("partial", isDirectory: true) }

    func partialURL(_ digest: String) -> URL {
        partialDir.appendingPathComponent(Digest.split(digest).1 + ".part")
    }

    /// Open (or create) the partial for `digest`, with its hash rebuilt from what is already on disk.
    func openPartial(_ digest: String) throws -> PartialBlob {
        if let shared = try openSharedPartial(digest) { return shared }
        // Someone else is filling this blob: use a scratch file of our own.
        let fm = FileManager.default
        try fm.createDirectory(at: paths.tmpDir, withIntermediateDirectories: true)
        let scratch = tempURL()
        let fd = open(scratch.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ImageError.io("open scratch blob: \(String(cString: strerror(errno)))") }
        return PartialBlob(url: scratch, fd: fd, isShared: false)
    }

    /// The shared partial, locked and rehashed, or nil when another puller holds it.
    func openSharedPartial(_ digest: String) throws -> PartialBlob? {
        guard Digest.isValid(digest) else { throw ImageError.invalid("bad digest \(digest)") }
        let fm = FileManager.default
        try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
        let path = partialURL(digest).path
        for _ in 0..<3 {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { break }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); break }
            var st = stat(), onDisk = stat()
            // The path must still name this inode: a discard or promote may have unlinked or replaced it before we got the lock.
            if fstat(fd, &st) != 0 || st.st_nlink == 0 || stat(path, &onDisk) != 0
                || onDisk.st_ino != st.st_ino || onDisk.st_dev != st.st_dev { Darwin.close(fd); continue }
            let p = PartialBlob(url: partialURL(digest), fd: fd, isShared: true)
            try p.rehash()
            return p
        }
        return nil
    }

    /// Delete partials nobody is writing, and return the bytes freed. `olderThan` keeps recent ones (nil removes all).
    @discardableResult
    public func sweepPartials(olderThan age: TimeInterval? = nil) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: partialDir.path) else { return 0 }
        var freed: Int64 = 0
        for n in names {
            let url = partialDir.appendingPathComponent(n)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if let age, let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < age, n.hasSuffix(".part") { continue }
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }       // a pull is using it
            if unlink(url.path) == 0 { freed += (attrs[.size] as? NSNumber)?.int64Value ?? 0 }
        }
        return freed
    }
}
