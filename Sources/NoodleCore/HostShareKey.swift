import Foundation

/// Names of host folders inside the guest's `/mnt/host` virtiofs share.
///
/// The key depends only on the folder (path and inode) and its access mode, never on the container. Every container
/// that binds the same folder therefore sees the same guest inodes, so the guest keeps its directory and attribute
/// caches between `docker run` invocations instead of starting cold each time. A folder recreated at the same path
/// gets a new key, because re-registering a key the guest has cached hangs or fails lookups.
/// Shape: `k` + 24 hex + `r` or `w`.
public enum HostShareKey {
    public static func key(directory: String, inode: UInt64, readOnly: Bool) -> String {
        "k" + String(Digest.sha256Hex(Data("\(inode):\(directory)".utf8)).prefix(24)) + (readOnly ? "r" : "w")
    }

    /// Inode of the folder now, or nil when nothing is there.
    public static func inode(of path: String) -> UInt64? {
        var info = stat()
        return stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// Guest path of a bind source: the folder itself, or the file inside its parent folder's share.
    public static func guestSource(hostPath: String, isDirectory: Bool, readOnly: Bool) -> String {
        let url = URL(fileURLWithPath: hostPath)
        let dir = isDirectory ? hostPath : url.deletingLastPathComponent().path
        return "/mnt/host/" + key(directory: dir, inode: inode(of: dir) ?? 0, readOnly: readOnly) + (isDirectory ? "" : "/" + url.lastPathComponent)
    }
}
