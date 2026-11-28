import Foundation

/// Size limits for request bodies that are spooled to disk (image load, image import, chunked archive uploads).
/// `NOODLE_MAX_UPLOAD_BYTES` overrides the default, mainly for tests.
public enum UploadLimits {
    public static let defaultBytes: Int64 = 32 << 30
    /// Disk space always left free for the VM and the image store.
    static let freeSpaceReserve: Int64 = 1 << 30

    public static var maximumBytes: Int64 {
        if let v = ProcessInfo.processInfo.environment["NOODLE_MAX_UPLOAD_BYTES"], let n = Int64(v), n > 0 { return n }
        return defaultBytes
    }

    public static let defaultCommitBytes: Int64 = 16 << 30
    /// The largest layer `docker commit` accepts from a container's filesystem. The workload VM runs code the Mac does not trust,
    /// so its output is capped like any other upload. `NOODLE_MAX_COMMIT_BYTES` overrides it.
    public static var commitMaximumBytes: Int64 {
        if let v = ProcessInfo.processInfo.environment["NOODLE_MAX_COMMIT_BYTES"], let n = Int64(v), n > 0 { return n }
        return defaultCommitBytes
    }

    public static let exceededMessage = "upload exceeds the size limit"

    /// The commit cap, further limited by the free space in `dir`.
    public static func commitAllowance(in dir: URL) -> Int64 {
        var limit = commitMaximumBytes
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            limit = min(limit, max(0, free - freeSpaceReserve))
        }
        return limit
    }

    /// Bytes the daemon will accept for a body that is written to `dir`: the limit, capped by free space minus a reserve.
    public static func allowance(in dir: URL) -> Int64 {
        var limit = maximumBytes
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            limit = min(limit, max(0, free - freeSpaceReserve))
        }
        return limit
    }
}
