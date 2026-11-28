import Foundation
import NoodleCore

extension Engine {
    /// Never wakes a VM or downloads a helper. Also used immediately before starting a link.
    public func publicLinkTarget(_ ref: String, port: Int?, allowPrivileged: Bool) throws -> PublicLinkTarget {
        guard !ref.isEmpty, !ref.contains(":"), !ref.contains("/"), !ref.contains("\\"), !ref.hasPrefix("-") else {
            throw EngineError.invalid("use a container name or ID, never a socket or URL")
        }
        let id = try resolveContainerID(ref)
        guard let c = containers[id], c.status == .running else { throw EngineError.invalid("container must be running") }
        // Same rule that sends a container to the workload VM: privileged and seccomp=unconfined both count.
        guard !Self.usesWorkload(c) || allowPrivileged else {
            throw EngineError.invalid("publishing a privileged or seccomp=unconfined container requires --allow-privileged")
        }
        let mode = c.hostConfig.NetworkMode
        guard mode != "host", mode != "none", !mode.hasPrefix("container:"), c.primaryNetwork != "host", c.primaryNetwork != "none",
              !c.primaryNetwork.hasPrefix("container:"),
              let ip = c.endpoints[c.primaryNetwork]?.ip, !ip.isEmpty, !ip.hasPrefix("127."), ip != "0.0.0.0" else {
            throw EngineError.invalid("public links require the container's own bridge address")
        }
        // A container that joined this one's network namespace shares its addresses and ports: publishing would expose it too.
        // A paused sibling still holds the namespace and can be resumed, so it counts as well.
        if let other = namespaceSiblings(of: id).first {
            throw EngineError.invalid("container \(other.name) shares this container's network namespace; stop it first, because the link would expose it too")
        }
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        // Socket mounts are capabilities. Refuse even when mounted under a different destination name.
        for mount in c.mounts {
            let source = URL(fileURLWithPath: mount.Source).resolvingSymlinksInPath().standardizedFileURL.path
            let destination = mount.Destination
            let sockets = [paths.socket.path, "/var/run/docker.sock", "/run/docker.sock"].map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
            if sockets.contains(where: { $0 == source || $0.hasPrefix(source + "/") }) || source.hasSuffix(".sock") || destination.hasSuffix(".sock") || source == resolved(paths.runDir) ||
                source == resolved(paths.root) || source == "/" || source == "/var/run" || source == "/run" ||
                (try? FileManager.default.attributesOfItem(atPath: source)[.type] as? FileAttributeType) == .typeSocket {
                throw EngineError.invalid("containers with socket mounts cannot be published")
            }
        }
        let keys = Set(Array((c.config.ExposedPorts ?? [:]).keys) + Array((c.hostConfig.PortBindings ?? [:]).keys) + Array(c.ports.keys))
        let ports = Set(keys.compactMap { key -> Int? in
            let pieces = key.split(separator: "/")
            guard pieces.count == 1 || (pieces.count == 2 && pieces[1] == "tcp"),
                  let p = Int(pieces[0]), (1...65535).contains(p) else { return nil }
            return p
        })
        guard let selected = port ?? (ports.count == 1 ? ports.first : nil), ports.contains(selected) else {
            throw EngineError.invalid("select a container TCP port declared with EXPOSE, --expose or --publish")
        }
        guard selected != 2375, selected != 2376 else { throw EngineError.invalid("Docker API ports cannot be published") }
        var warnings: [String] = []
        if Self.usesWorkload(c) { warnings.append("it is privileged or seccomp=unconfined (--allow-privileged)") }
        if !(c.hostConfig.CapAdd ?? []).isEmpty { warnings.append("it was granted extra capabilities: \((c.hostConfig.CapAdd ?? []).joined(separator: ", "))") }
        if c.hostConfig.PidMode == "host" { warnings.append("it uses the host PID namespace") }
        return PublicLinkTarget(containerID: id, containerName: c.name, containerIP: ip, containerPort: selected, warnings: warnings)
    }

    /// The CLI that supervises one helper. Resolved from the real executable path, never argv[0] (which may be relative).
    /// In an app bundle, `Contents/MacOS` holds the GUI binary `Noodle`, which a case-insensitive lookup of `noodle` would hit,
    /// so the CLI comes from `Contents/Helpers`. Elsewhere it must be a sibling whose on-disk name is exactly `noodle`.
    nonisolated static func linkSupervisorURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return linkSupervisorURL(executable: URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath())
    }

    nonisolated static func linkSupervisorURL(executable exe: URL) -> URL? {
        let fm = FileManager.default
        let dir = exe.deletingLastPathComponent()
        let inBundle = dir.lastPathComponent == "MacOS" && dir.deletingLastPathComponent().lastPathComponent == "Contents"
        let helperDir = inBundle ? dir.deletingLastPathComponent().appendingPathComponent("Helpers") : dir
        guard (try? fm.contentsOfDirectory(atPath: helperDir.path))?.contains("noodle") == true else { return nil }
        let candidate = helperDir.appendingPathComponent("noodle").resolvingSymlinksInPath()
        guard helperDir.lastPathComponent != "MacOS", fm.isExecutableFile(atPath: candidate.path) else { return nil }
        func inode(_ url: URL) -> UInt64? { (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? nil }
        guard let mine = inode(exe), let theirs = inode(candidate), mine != theirs else { return nil }
        return candidate
    }
}
