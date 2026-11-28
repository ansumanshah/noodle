import Foundation

/// Pure planning for `noodle import`: what to copy and what to leave alone, decided from engine JSON only.
public enum ImportPlan {
    public typealias JSON = [String: Any]

    /// What identifies an image on the source: its tags, or its digest references when it has no tag
    /// (a digest-pinned image is what a container created from `repo@sha256:...` leaves behind).
    public static func imageRefs(tags: [String], digests: [String]) -> [String] {
        let tags = tags.filter { $0 != "<none>:<none>" }
        if !tags.isEmpty { return tags }
        return digests.filter { $0 != "<none>@<none>" && $0.contains("@sha256:") }
    }

    public enum ImageAction: Equatable, Sendable { case present, copy([String]) }

    /// An image with no tag moves by ID once; a rerun finds the ID on the target and leaves it.
    public static func untaggedImageAction(id: String, targetHas: (String) -> Bool) -> ImageAction {
        targetHas(id) ? .present : .copy([id])
    }

    /// Names of volumes that any container (running or not) mounts, from container inspect documents.
    public static func volumesInUse(containerInspects: [JSON]) -> Set<String> {
        var used = Set<String>()
        for c in containerInspects {
            for m in c["Mounts"] as? [JSON] ?? [] where m["Type"] as? String == "volume" {
                if let n = m["Name"] as? String, !n.isEmpty { used.insert(n) }
            }
            // A container that never started may list its volumes only in HostConfig.
            let host = c["HostConfig"] as? JSON ?? [:]
            for m in host["Mounts"] as? [JSON] ?? [] where m["Type"] as? String == "volume" {
                if let n = m["Source"] as? String, !n.isEmpty { used.insert(n) }
            }
            for b in host["Binds"] as? [String] ?? [] {
                let first = b.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if !first.isEmpty, !first.hasPrefix("/") { used.insert(first) }
            }
        }
        return used
    }

    /// The user-defined network a container is attached to and the aliases it has there.
    /// Nil for the default bridge, host, none and `container:` modes, which exist everywhere.
    public static func network(hostConfig: JSON, networks: JSON) -> (name: String, aliases: [String])? {
        let mode = hostConfig["NetworkMode"] as? String ?? "default"
        guard !["default", "bridge", "host", "none", ""].contains(mode), !mode.hasPrefix("container:") else { return nil }
        let aliases = (networks[mode] as? JSON)?["Aliases"] as? [String] ?? []
        return (mode, aliases)
    }

    /// Networks to create on the target, each once, however many containers share it.
    public static func networksToCreate(wanted: [String], existing: Set<String>) -> [String] {
        var seen = existing
        return wanted.filter { seen.insert($0).inserted }
    }

    /// Plain words for a source engine that does not answer.
    public static func sourceNotRunning(source: String, socketPath: String, socketExists: Bool) -> String {
        let app: String
        switch source.lowercased() {
        case "orbstack": app = "OrbStack"
        case "desktop-linux", "desktop": app = "Docker Desktop"
        case "podman": app = "Podman"
        default: app = "the source engine (\(source))"
        }
        let why = socketExists ? "its socket at \(socketPath) does not answer" : "there is no socket at \(socketPath)"
        return "\(app) is not running: \(why). Start it, then run noodle import again. noodle import never starts another engine."
    }
}
