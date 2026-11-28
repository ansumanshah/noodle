import Darwin
import Foundation

/// Private, atomic local storage. Never follows an existing file or models-directory symlink.
enum ModelChatPersistence {
    static func validate(_ file: URL) throws {
        for url in [file.deletingLastPathComponent(), file] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true,
                  url == file ? values.isRegularFile == true : values.isDirectory == true else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
    }

    static func write(_ data: Data, to file: URL) throws {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileWriteNoPermission) }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: file.path) { try validate(file) }
        let temporary = directory.appendingPathComponent(".chat-history-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        defer { if !closed { close(descriptor) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        // F_FULLFSYNC reaches the disk; plain fsync on macOS may stop at the drive cache.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        closed = true
        guard close(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Persist the rename itself so a crash cannot leave the old name pointing at stale data.
        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }
}
