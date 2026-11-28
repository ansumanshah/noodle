import Foundation

// Disk cleanup for Noodle Runners: a pure planner over an inventory, so the CLI executes it and a low-disk check
// can call it later. Tiers run from the cheapest to rebuild to the dearest.

public enum RunnerCleanTier: Int, Codable, CaseIterable, Sendable {
    case leftovers = 1, logs, runnerDownloads, repoCaches, runnerImages

    public var title: String {
        switch self {
        case .leftovers: "Leftovers from finished or crashed jobs"
        case .logs: "Old runner logs"
        case .runnerDownloads: "Old GitHub runner downloads"
        case .repoCaches: "Unused per-repo toolchain caches"
        case .runnerImages: "Old runner images"
        }
    }
}

public enum RunnerCleanKind: String, Codable, Sendable { case folder, container, volume, image }

public struct RunnerCleanItem: Codable, Equatable, Sendable {
    public var tier: RunnerCleanTier
    public var kind: RunnerCleanKind
    /// A path for a folder, else the container, volume or image name or id.
    public var ref: String
    public var bytes: Int64
    /// Nil when unknown. Tiers with a cutoff keep an item whose age is unknown.
    public var lastUsed: Date?
    /// `owner/repo` the item belongs to, so a repo with a job in progress can be skipped.
    public var repo: String?
    /// True while a running job, runner or process holds this item.
    public var busy: Bool
    /// The pinned runner version an install or image belongs to; the current one is kept.
    public var version: String?
    /// For an image tag: the image it names. Its bytes count once, and only when every tag of it goes.
    public var imageID: String?

    public init(tier: RunnerCleanTier, kind: RunnerCleanKind, ref: String, bytes: Int64 = 0, lastUsed: Date? = nil, repo: String? = nil,
                busy: Bool = false, version: String? = nil, imageID: String? = nil) {
        self.tier = tier; self.kind = kind; self.ref = ref; self.bytes = bytes; self.lastUsed = lastUsed
        self.repo = repo; self.busy = busy; self.version = version; self.imageID = imageID
    }
}

public struct RunnerCleanInventory: Sendable {
    /// Folders are only deleted inside this one (the `runners` folder).
    public var root: URL
    public var items: [RunnerCleanItem]
    /// Lowercased `owner/repo` with a job in progress.
    public var busyRepos: Set<String>
    /// True when a job runs but the repo is unknown, so every repo counts as busy.
    public var allReposBusy: Bool
    public init(root: URL, items: [RunnerCleanItem], busyRepos: Set<String> = [], allReposBusy: Bool = false) {
        self.root = root; self.items = items; self.busyRepos = busyRepos; self.allReposBusy = allReposBusy
    }
}

public struct RunnerCleanOptions: Sendable {
    public static let defaultDays = 14
    public var olderThanDays: Int
    public var currentVersion: String
    public var now: Date
    public init(olderThanDays: Int = RunnerCleanOptions.defaultDays, currentVersion: String = RunnerPin.version, now: Date = Date()) {
        self.olderThanDays = olderThanDays; self.currentVersion = currentVersion; self.now = now
    }
    var cutoff: Date { now.addingTimeInterval(-Double(olderThanDays) * 86_400) }
}

public struct RunnerCleanStep: Codable, Equatable, Sendable {
    public var item: RunnerCleanItem
    /// Why it is deleted, or why it is kept.
    public var reason: String
}

public struct RunnerCleanPlan: Equatable, Sendable {
    /// Ordered by tier.
    public var deletions: [RunnerCleanStep]
    public var skipped: [RunnerCleanStep]
}

public enum RunnerCleanPlanner {
    /// True when `path` resolves, after symlinks, to a place strictly inside `root`.
    public static func inside(root: URL, path: String) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return target.hasPrefix(base + "/")
    }

    public static func plan(_ inventory: RunnerCleanInventory, _ options: RunnerCleanOptions) -> RunnerCleanPlan {
        var deletions: [RunnerCleanStep] = [], skipped: [RunnerCleanStep] = []
        let ordered = inventory.items.enumerated().sorted { ($0.element.tier.rawValue, $0.offset) < ($1.element.tier.rawValue, $1.offset) }
        for item in ordered.map(\.element) {
            switch verdict(item, inventory, options) {
            case .delete(let why): deletions.append(.init(item: item, reason: why))
            case .keep(let why): skipped.append(.init(item: item, reason: why))
            }
        }
        return RunnerCleanPlan(deletions: deletions, skipped: skipped)
    }

    private enum Verdict { case delete(String), keep(String) }

    private static func verdict(_ item: RunnerCleanItem, _ inv: RunnerCleanInventory, _ o: RunnerCleanOptions) -> Verdict {
        if item.kind == .folder, !inside(root: inv.root, path: item.ref) { return .keep("outside the Runners folder") }
        if item.busy { return .keep(item.kind == .image ? "used by a container" : "in use by a running job") }
        if let repo = item.repo, inv.allReposBusy || inv.busyRepos.contains(repo.lowercased()) { return .keep("\(repo) has a job in progress") }
        if item.version == o.currentVersion { return .keep("current runner version") }
        switch item.tier {
        case .leftovers, .runnerDownloads: return .delete(item.tier == .leftovers ? "left behind by a finished job" : "older than the pinned runner")
        case .logs, .repoCaches, .runnerImages:
            if item.tier == .runnerImages, !RunnerCleanRules.isPlainVersion(item.version ?? "") { return .keep("not a versioned runner image") }
            guard let used = item.lastUsed else { return .keep("last use unknown") }
            guard used < o.cutoff else { return .keep("used within \(o.olderThanDays) days") }
            return .delete("not used for \(o.olderThanDays) days")
        }
    }
}

/// The busy and keep decisions the inventory makes, pure so tests can run them.
public enum RunnerCleanRules {
    /// A work folder is busy when a runner has its name, anything touched it recently, or a live process works inside it.
    /// The helper being off proves nothing: a killed helper leaves job processes alive.
    public static func folderBusy(path: String, running: Set<String>, touched: Date?, now: Date, grace: TimeInterval,
                                  processDirectories: [String]?) -> Bool {
        if running.contains((path as NSString).lastPathComponent) { return true }
        // nil: the process list could not be read, so a live job may be working here.
        guard let processDirectories else { return true }
        guard let touched, now.timeIntervalSince(touched) >= grace else { return true }
        let path = resolved(path)
        return processDirectories.contains { inside(resolved($0), path) }
    }

    /// lsof prints resolved paths (/private/tmp), the folder list may not (/tmp): compare both resolved.
    /// Foundation drops /private only for paths that exist, so drop it here too.
    static func resolved(_ p: String) -> String {
        let r = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        return r.hasPrefix("/private/") ? String(r.dropFirst("/private".count)) : r
    }

    private static func inside(_ d: String, _ folder: String) -> Bool { d == folder || d.hasPrefix(folder + "/") }

    /// Never signal the kernel, launchd or the helper itself.
    public static func signalable(_ pid: Int32, ownPID: Int32) -> Bool { pid > 1 && pid != ownPID }

    /// Each process with its working directory from `lsof -a -d cwd -Fpn`, or nil when the list is unknown.
    /// lsof exits 1 when it could not read some processes, so 1 with a list is still a list; 124 (timeout),
    /// 127 (no lsof), any other code, or no entries at all (lsof always lists itself) mean unknown.
    public static func processDirectories(lsofOutput: String, code: Int32, ownPID: Int32) -> [(pid: Int32, path: String)]? {
        guard code == 0 || code == 1 else { return nil }
        var found: [(pid: Int32, path: String)] = [], pid: Int32?
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) } else if line.hasPrefix("n"), let pid { found.append((pid, String(line.dropFirst()))) }
        }
        if found.isEmpty { return nil }
        return found.filter { signalable($0.pid, ownPID: ownPID) }
    }

    /// Processes working in the work folder `name` or below it. The folder path is the resolved work directory plus
    /// the entry's own name, never the entry resolved: a symlinked entry must not lead to processes elsewhere.
    public static func pids(inWorkFolder name: String, workDirectory: String, processes: [(pid: Int32, path: String)]) -> [Int32] {
        let folder = resolved(workDirectory) + "/" + name
        return processes.filter { inside(resolved($0.path), folder) }.map(\.pid)
    }

    /// Never a container a runner owns, and never one that is only created: it may be about to start.
    public static func containerCandidate(name: String, status: String, running: Set<String>) -> Bool {
        !running.contains(name) && status != "created" && ["exited", "dead"].contains(status)
    }

    /// One item per runner tag, since `docker rmi <tag>` removes one tag. Each tag carries its image's size when removing
    /// the tags frees it (every tag is an old runner version); the report counts it once per image. An image a container
    /// uses, even a stopped one, is busy. `usedIDs` nil means the container list could not be read: every image is busy.
    public static func runnerImageItems(_ images: [(id: String, tags: [String], bytes: Int64, created: Date?)], repository: String,
                                        usedIDs: Set<String>?, currentVersion: String = RunnerPin.version) -> [RunnerCleanItem] {
        let prefix = repository + ":"
        var items: [RunnerCleanItem] = []
        for image in images {
            let tags = image.tags.filter { $0.hasPrefix(prefix) }
            let versions = tags.map { String($0.dropFirst(prefix.count)) }
            let freed = tags.count == image.tags.count && versions.allSatisfy { isPlainVersion($0) && $0 != currentVersion }
            for (i, tag) in tags.enumerated() {
                items.append(.init(tier: .runnerImages, kind: .image, ref: tag, bytes: freed ? image.bytes : 0,
                                   lastUsed: image.created, busy: usedIDs?.contains(image.id) ?? true, version: versions[i], imageID: image.id))
            }
        }
        return items
    }

    /// Only `N.N.N` tags are runner versions; `latest` and anything else is never a candidate.
    public static func isPlainVersion(_ tag: String) -> Bool {
        tag.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    /// Runs the plan. Folders are removed here, only inside `root`; `external` removes containers, volumes and images.
    /// A dry run removes nothing and reports every step as done. `stillFree` is asked right before each removal, since a
    /// job may have started after planning; a step it refuses is kept and returned in `busy`.
    public static func execute(_ plan: RunnerCleanPlan, root: URL, dryRun: Bool, stillFree: (RunnerCleanItem) -> Bool = { _ in true },
                               external: (RunnerCleanItem) -> Bool)
        -> (done: [RunnerCleanStep], failed: [RunnerCleanStep], busy: [RunnerCleanStep]) {
        var done: [RunnerCleanStep] = [], failed: [RunnerCleanStep] = [], busy: [RunnerCleanStep] = []
        for step in plan.deletions {
            if dryRun { done.append(step); continue }
            guard stillFree(step.item) else { busy.append(.init(item: step.item, reason: "in use by a running job")); continue }
            let ok: Bool
            if step.item.kind == .folder {
                // Checked again at the moment of deletion, in case a symlink appeared after planning.
                ok = RunnerCleanPlanner.inside(root: root, path: step.item.ref) && (try? FileManager.default.removeItem(atPath: step.item.ref)) != nil
            } else { ok = external(step.item) }
            if ok { done.append(step) } else { failed.append(step) }
        }
        return (done, failed, busy)
    }
}

/// What `noodle runners clean --json` prints.
public struct RunnerCleanReport: Codable, Equatable, Sendable {
    public struct TierTotal: Codable, Equatable, Sendable {
        public var tier: Int
        public var title: String
        public var items: Int
        /// Bytes freed, or bytes that would be freed on a dry run.
        public var bytes: Int64
    }
    public var dryRun: Bool
    /// False when the engine was down, so container, volume and image tiers were not checked.
    public var engine: Bool
    public var tiers: [TierTotal]
    public var totalBytes: Int64
    public var deleted: [RunnerCleanStep]
    public var skipped: [RunnerCleanStep]
    public var failed: [RunnerCleanStep]
    /// User-owned folders a macOS job may write to. Never touched.
    public var leftAlone: [String]

    public init(dryRun: Bool, engine: Bool = true, deleted: [RunnerCleanStep], skipped: [RunnerCleanStep], failed: [RunnerCleanStep], leftAlone: [String]) {
        self.dryRun = dryRun; self.engine = engine; self.deleted = deleted; self.skipped = skipped; self.failed = failed; self.leftAlone = leftAlone
        // An image is freed only when every tag of it went, and then counts once.
        let kept = Set((skipped + failed).compactMap(\.item.imageID))
        var credited = Set<String>()
        func freed(_ item: RunnerCleanItem) -> Int64 {
            guard let id = item.imageID else { return item.bytes }
            return !kept.contains(id) && credited.insert(id).inserted ? item.bytes : 0
        }
        tiers = RunnerCleanTier.allCases.map { t in
            let mine = deleted.filter { $0.item.tier == t }
            return TierTotal(tier: t.rawValue, title: t.title, items: mine.count, bytes: mine.reduce(0) { $0 + freed($1.item) })
        }
        totalBytes = tiers.reduce(0) { $0 + $1.bytes }
    }
}
