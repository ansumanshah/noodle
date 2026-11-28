import Foundation
import NoodleCore
import NoodleImages

extension Engine {

    // MARK: list / inspect

    func summary(_ img: LocalImage) -> ImageSummary {
        var s = ImageSummary()
        s.Id = img.id; s.ParentId = img.parent
        s.RepoTags = img.repoTags.isEmpty ? ["<none>:<none>"] : img.repoTags
        s.RepoDigests = img.repoDigests.isEmpty ? ["<none>@<none>"] : img.repoDigests
        if img.repoTags.isEmpty && img.repoDigests.isEmpty { s.RepoTags = []; s.RepoDigests = [] }
        s.Created = Int64(img.created.timeIntervalSince1970)
        s.Size = img.size; s.VirtualSize = img.size
        s.Labels = img.config.config?.labels ?? [:]
        s.Containers = containers.values.filter { $0.imageID == img.id }.count
        return s
    }

    public func listImages(all: Bool = false, filters: Filters = Filters()) async -> [ImageSummary] {
        var f = ImageListFilter()
        f.references = filters["reference"]; f.dangling = filters.bool("dangling"); f.labels = filters["label"]
        f.before = filters["before"].first; f.since = filters["since"].first
        return await imageStore.list(all: all, filter: f).map { summary($0) }
    }

    func containerConfig(from c: ImageConfig.RuntimeConfig?) -> ContainerConfig {
        var cfg = ContainerConfig()
        guard let c else { return cfg }
        cfg.User = c.user ?? ""; cfg.Env = c.env; cfg.Cmd = c.cmd; cfg.Entrypoint = c.entrypoint; cfg.WorkingDir = c.workingDir ?? ""
        cfg.Labels = c.labels; cfg.ExposedPorts = c.exposedPorts?.mapValues { _ in EmptyStruct() }
        cfg.Volumes = c.volumes?.mapValues { _ in EmptyStruct() }; cfg.StopSignal = c.stopSignal; cfg.Shell = c.shell
        if let h = c.healthcheck { var hc = HealthConfig(); hc.Test = h.test; hc.Interval = h.interval; hc.Timeout = h.timeout; hc.StartPeriod = h.startPeriod; hc.StartInterval = h.startInterval; hc.Retries = h.retries; cfg.Healthcheck = hc }
        return cfg
    }

    public func inspectImage(_ name: String) async throws -> ImageInspect {
        let img: LocalImage
        do { img = try await imageStore.resolve(name) } catch { throw mapImageError(error, name) }
        var i = ImageInspect()
        i.Id = img.id; i.RepoTags = img.repoTags; i.RepoDigests = img.repoDigests; i.Parent = img.parent; i.Comment = img.comment
        i.Created = img.config.created ?? ISO8601.string(img.created); i.Author = img.config.author ?? ""
        i.Config = containerConfig(from: img.config.config)
        i.Architecture = img.architecture; i.Variant = img.variant; i.Os = img.os
        i.Size = img.size; i.VirtualSize = img.size
        i.RootFS.Layers = img.layers.map(\.diffID)
        return i
    }

    public func imageHistory(_ name: String) async throws -> [ImageHistoryEntry] {
        do {
            return try await imageStore.history(name).map {
                ImageHistoryEntry(Id: $0.id, Created: Int64($0.created.timeIntervalSince1970), CreatedBy: $0.createdBy,
                                  Tags: $0.tags, Size: $0.size, Comment: $0.comment)
            }
        } catch { throw mapImageError(error, name) }
    }
}

extension ImageError {
    var isNotFound: Bool { if case .notFound = self { return true }; return false }
}
