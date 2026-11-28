import Foundation

extension Notification.Name {
    /// Posted after an explicit Refresh, so the Overview reads the disk figures again.
    static let overviewRefresh = Notification.Name("dev.noodle.overview.refresh")
}

/// Disk numbers for the Overview. `reclaimable` is exactly what Clean Up frees: what Docker's standard
/// prune removes (stopped containers, images with no tag and no digest that no remaining container uses,
/// unused networks), never volumes or tagged images.
struct OverviewDisk: Equatable, Sendable {
    var used = 0
    var reclaimable = 0
    var stoppedContainers = 0
    var untaggedImages = 0
    /// Removable things count even when the daemon reports no bytes for them.
    var canClean: Bool { reclaimable > 0 || stoppedContainers > 0 || untaggedImages > 0 }

    /// What Clean Up would remove, in plain words.
    var summary: String {
        var parts: [String] = []
        if stoppedContainers > 0 { parts.append("\(stoppedContainers) stopped container\(stoppedContainers == 1 ? "" : "s")") }
        if untaggedImages > 0 { parts.append("\(untaggedImages) untagged image\(untaggedImages == 1 ? "" : "s")") }
        parts.append("unused networks")
        return parts.joined(separator: ", ")
    }
}

enum OverviewDiskSource {
    private struct Image: Decodable { var Id: String?; var RepoTags: [String]?; var RepoDigests: [String]?; var Size: Int? }
    private struct Container: Decodable { var State: String?; var SizeRw: Int?; var ImageID: String? }
    private struct Volume: Decodable { struct Usage: Decodable { var Size: Int? }; var UsageData: Usage? }
    private struct DF: Decodable { var LayersSize: Int?; var Images: [Image]?; var Containers: [Container]?; var Volumes: [Volume]? }

    /// Reads the daemon's own `/system/df`.
    static func load(socketPath: String) async -> OverviewDisk? {
        guard let r = try? await DockerSocket(path: socketPath).request("GET", "/system/df", timeout: 30), r.status < 300 else { return nil }
        return summarize(r.body)
    }

    /// Turns a `/system/df` body into the Overview numbers. Clean Up removes stopped containers first and then
    /// images nothing uses, so an image counts when only stopped containers still point at it.
    static func summarize(_ body: Data) -> OverviewDisk? {
        guard let df = try? JSONDecoder().decode(DF.self, from: body) else { return nil }
        var disk = OverviewDisk()
        let images = df.Images ?? []
        let layers = df.LayersSize ?? images.reduce(0) { $0 + max(0, $1.Size ?? 0) }
        disk.used = layers
            + (df.Volumes ?? []).reduce(0) { $0 + max(0, $1.UsageData?.Size ?? 0) }
            + (df.Containers ?? []).reduce(0) { $0 + max(0, $1.SizeRw ?? 0) }
        var staying = Set<String>()
        for c in df.Containers ?? [] {
            if stopped(c.State) {
                disk.stoppedContainers += 1; disk.reclaimable += max(0, c.SizeRw ?? 0)
            } else if let image = c.ImageID {
                staying.insert(image)
            }
        }
        for i in images where isDangling(tags: i.RepoTags, digests: i.RepoDigests) && !staying.contains(i.Id ?? "") {
            disk.untaggedImages += 1; disk.reclaimable += max(0, i.Size ?? 0)
        }
        return disk
    }

    /// Demo mode has no daemon, so the same numbers come from the demo lists.
    static func demo(images: [ImageSummary], containers: [ContainerSummary]) -> OverviewDisk {
        var disk = OverviewDisk()
        disk.used = images.reduce(0) { $0 + $1.size }
        disk.stoppedContainers = containers.filter { !$0.isRunning }.count
        for i in images where isDangling(tags: i.repoTags, digests: nil) && i.containers <= 0 {
            disk.untaggedImages += 1; disk.reclaimable += i.size
        }
        return disk
    }

    private static func stopped(_ state: String?) -> Bool { !["running", "paused", "restarting"].contains(state ?? "") }

    /// The image store prunes only an image with no tag and no digest. The daemon lists the placeholders
    /// `<none>:<none>` and `<none>@<none>` for the missing half, which are not real references.
    static func isDangling(tags: [String]?, digests: [String]?) -> Bool {
        (tags ?? []).allSatisfy { $0.hasPrefix("<none>") } && (digests ?? []).allSatisfy { $0.hasPrefix("<none>") }
    }

    /// Docker's standard prune: containers, dangling images, networks. Returns the bytes freed.
    static func cleanUp(socketPath: String) async throws -> Int {
        let socket = DockerSocket(path: socketPath)
        var freed = 0
        for target in ["/containers/prune", "/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D", "/networks/prune"] {
            let r = try await socket.request("POST", target, timeout: 120)
            guard r.status < 300 else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
            freed += ((try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["SpaceReclaimed"] as? NSNumber)?.intValue ?? 0
        }
        return freed
    }
}
