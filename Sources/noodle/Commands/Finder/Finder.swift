import Darwin
import Foundation

private struct FinderCLIStatus: Codable {
    let url: String?
    let mounted: Bool
    let mountpoint: String?
}

private var finderHelp: String { CommandTable.groupHelp("finder") }

private func finderDirectory(_ path: String, create: Bool) throws -> String {
    var absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    // macOS exposes these system directories through fixed aliases. Never resolve user symlinks.
    for alias in ["/tmp", "/var"] {
        if absolute == alias || absolute.hasPrefix(alias + "/") {
            absolute = "/private" + absolute
            break
        }
    }
    // Check before normalizing so a symlink followed by '..' cannot disappear.
    let components = absolute.split(separator: "/").filter { $0 != "." }
    var current = ""
    for (index, component) in components.enumerated() {
        guard component != ".." else { throw ImportError.fatal("Finder paths must not contain '..'") }
        current += "/" + component
        var info = stat()
        if lstat(current, &info) != 0 {
            guard errno == ENOENT, create, index == components.count - 1 else {
                throw ImportError.fatal("Finder directory does not exist: \(current)")
            }
            guard mkdir(current, 0o700) == 0, lstat(current, &info) == 0 else {
                throw ImportError.fatal("cannot create Finder directory: \(current)")
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ImportError.fatal("Finder paths must contain real directories, without symlinks: \(current)")
        }
    }
    guard !current.isEmpty else { throw ImportError.fatal("cannot use the filesystem root as a Finder directory") }
    var info = stat()
    guard lstat(current, &info) == 0, info.st_uid == getuid() else {
        throw ImportError.fatal("Finder directory must be owned by the current user: \(current)")
    }
    return current
}

func cmdFinder(_ args: [String]) {
    guard let command = args.first, ["mount", "unmount", "status"].contains(command) else {
        if args.isEmpty || args == ["help"] || args == ["--help"] || args == ["-h"] { out(finderHelp); return }
        usageDie(finderHelp)
    }
    guard (command == "mount" && args.count <= 2) || (command != "mount" && args.count == 1) else { usageDie(finderHelp) }
    if command == "mount", let argument = args.dropFirst().first, argument.hasPrefix("-"), argument != "--serve-only" { usageDie(finderHelp) }
    do {
        let endpoint = EngineEndpoint(name: "Finder", socketPath: socketPath)
        func status() throws -> FinderCLIStatus {
            try JSONDecoder().decode(FinderCLIStatus.self, from: endpoint.call("GET", "/noodle/finder").body)
        }
        func printStatus(_ value: FinderCLIStatus) throws {
            let object: [String: Any] = [
                "url": value.url.map { $0 as Any } ?? NSNull(),
                "mounted": value.mounted,
                "mountpoint": value.mountpoint.map { $0 as Any } ?? NSNull(),
            ]
            out(jsonLine(object))
        }
        if command == "status" { try printStatus(status()); return }
        let runDirectory = try finderDirectory(paths.runDir.path, create: false)
        let lock = open(runDirectory + "/finder.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ImportError.fatal("cannot open Finder operation lock") }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              flock(lock, LOCK_EX) == 0 else { throw ImportError.fatal("cannot lock Finder operations") }
        defer { _ = flock(lock, LOCK_UN) }
        let before = try status()
        if command == "unmount" {
            if before.mounted {
                guard let mountpoint = before.mountpoint else { throw ImportError.fatal("Finder mount has no mountpoint") }
                let result = run("/sbin/umount", [mountpoint])
                guard result.code == 0 else { throw ImportError.fatal("Finder unmount failed; server retained (the mount may be busy)") }
            }
            _ = try endpoint.call("DELETE", "/noodle/finder")
            out("Finder stopped")
            return
        }
        let serveOnly = args.dropFirst().first == "--serve-only"
        if before.mounted {
            if serveOnly || args.count == 1 || args[1] == before.mountpoint { out("Finder is already mounted"); return }
            throw ImportError.fatal("Finder is already mounted; unmount it before choosing another directory")
        }
        let mountpoint = try serveOnly ? nil : finderDirectory(args.dropFirst().first ?? runDirectory + "/finder", create: true)
        if let mountpoint {
            guard try FileManager.default.contentsOfDirectory(atPath: mountpoint).isEmpty else {
                throw ImportError.fatal("Finder mountpoint must be empty: \(mountpoint)")
            }
        }
        let body: [String: Any] = ["mountpoint": mountpoint.map { $0 as Any } ?? NSNull()]
        let reply = try endpoint.call("POST", "/noodle/finder", json: body)
        let started = try JSONDecoder().decode(FinderCLIStatus.self, from: reply.body)
        guard let mountpoint else { out("Finder server started"); return }
        guard let url = started.url else {
            _ = try? endpoint.call("DELETE", "/noodle/finder")
            throw ImportError.fatal("Finder server returned no mount URL")
        }
        let result = run("/sbin/mount_webdav", ["-S", "-v", "Noodle", "-o", "rdonly,nosuid,nodev,noexec", url, mountpoint])
        guard result.code == 0 else {
            let rollback = (try? endpoint.call("DELETE", "/noodle/finder")) != nil
            throw ImportError.fatal("Finder mount failed (exit \(result.code)); \(rollback ? "server stopped" : "server cleanup failed; run noodle finder unmount"). Check mountpoint permissions and macOS WebDAV support.")
        }
        out("Finder mounted at \(mountpoint)")
    } catch { die(error) }
}
