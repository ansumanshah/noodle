import Foundation

private let dataFolderMarker = ".noodle-data"
private let dataFolderIdentity = "dev.getnoodle.data.v1\n"

func setupMarkDataFolder() throws {
    try dataFolderIdentity.write(to: paths.root.appendingPathComponent(dataFolderMarker), atomically: true, encoding: .utf8)
}

/// Resolve symlinks before checking ancestry. A marker never authorizes deleting a user's home.
func setupVerifyDataDeletion() throws {
    let root = paths.root.resolvingSymlinksInPath().standardizedFileURL
    let accountHome = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
    let homes = [URL(fileURLWithPath: home), FileManager.default.homeDirectoryForCurrentUser, accountHome].compactMap { $0 }
        .map { $0.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
    let comparison = root.path.precomposedStringWithCanonicalMapping.lowercased()
    guard comparison != "/", !homes.contains(where: { $0 == comparison || $0.hasPrefix(comparison + "/") }) else {
        throw CLIError("refusing to delete protected data folder \(root.path)")
    }
    let marker = root.appendingPathComponent(dataFolderMarker)
    guard (try? setupFM.attributesOfItem(atPath: marker.path)[.type]) as? FileAttributeType == .typeRegular,
          (try? String(contentsOf: marker, encoding: .utf8)) == dataFolderIdentity else {
        throw CLIError("refusing to delete unverified Noodle data folder \(root.path). Run noodle setup to record this installation first.")
    }
}

/// Keep each helper's lock until uninstall exits, so a stopped machine cannot start during cleanup.
func setupLockStoppedMachines() throws -> [Int32] {
    guard setupFM.fileExists(atPath: machinesRoot.path) else { return [] }
    var locks: [Int32] = []
    do {
        for name in try setupFM.contentsOfDirectory(atPath: machinesRoot.path) {
            let directory = machinesRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard setupFM.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CLIError("cannot check Linux machine \(name); installation preserved") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw CLIError("Linux machine \(name) is running. Run noodle machine stop \(name) before uninstalling.")
            }
            locks.append(fd)
        }
        return locks
    } catch {
        for fd in locks { close(fd) }
        throw error
    }
}

func setupCleanProfiles(_ receipt: [String: String]) throws {
    for (key, value) in receipt where key.hasPrefix("profile:") {
        let profile = URL(fileURLWithPath: String(key.dropFirst(8))).resolvingSymlinksInPath()
        // Missing files need no cleanup. Read and write errors must retain the receipt for a retry.
        do {
            var attributes = stat()
            if lstat(profile.path, &attributes) != 0 {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let text = try String(contentsOf: profile, encoding: .utf8)
            guard text.contains(value) else { continue }
            let remaining = text.replacingOccurrences(of: value, with: "")
            if remaining.isEmpty && receipt["created-profile:" + profile.path] == "1" {
                try setupFM.removeItem(at: profile)
            } else {
                let mode = try setupFM.attributesOfItem(atPath: profile.path)[.posixPermissions]
                try remaining.write(to: profile, atomically: true, encoding: .utf8)
                if let mode { try setupFM.setAttributes([.posixPermissions: mode], ofItemAtPath: profile.path) }
            }
        } catch {
            throw CLIError("cannot clean PATH profile \(profile.path): \(error.localizedDescription). Setup information kept; fix the file and retry uninstall.")
        }
    }
}
