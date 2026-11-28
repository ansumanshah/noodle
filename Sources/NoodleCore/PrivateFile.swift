import Foundation

/// Writes a secret so it is never readable by others: created 0600, then renamed over the old file.
public enum PrivateFile {
    /// `ownFolder: false` for a folder other tools share (HF_HOME): created 0700 if missing, left alone if it exists.
    public static func write(_ data: Data, to file: URL, ownFolder: Bool = true) throws {
        let folder = file.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if ownFolder { try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let temp = folder.appendingPathComponent(".tmp-" + UUID().uuidString)
        guard files.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        if rename(temp.path, file.path) != 0 {
            let code = errno
            try? files.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
