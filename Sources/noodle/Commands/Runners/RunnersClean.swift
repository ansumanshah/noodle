import Foundation
import NoodleCore

// noodle runners clean: frees disk Runners used, tier by tier. The plan is pure (RunnerCleanPlanner); this file
// reads the inventory, runs the plan and prints the report.

// A runner just spawned may not be in state.json yet, and a job's folder is written to while it runs.
private let leftoverGrace: TimeInterval = 600
private let imageRepository = "ghcr.io/actions/actions-runner"

func runnersCleanArgs(_ rest: [String]) -> (dryRun: Bool, json: Bool, days: Int) {
    var dryRun = false, json = false, days = RunnerCleanOptions.defaultDays, i = 0
    while i < rest.count {
        switch rest[i] {
        case "--dry-run": dryRun = true
        case "--json": json = true
        case "--older-than":
            i += 1
            guard i < rest.count, let n = Int(rest[i]), n >= 0 else { die(runnersUsage, code: 2) }
            days = n
        default: die(runnersUsage, code: 2)
        }
        i += 1
    }
    return (dryRun, json, days)
}

private func dockerJSON(_ target: String) -> Any? {
    guard let r = httpGet(target, timeoutSeconds: 60), r.status == 200 else { return nil }
    return try? JSONSerialization.jsonObject(with: r.body)
}

private func children(_ folder: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
}

private func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Newest modification time in the folder and up to 5000 entries below it: a job writing only in subfolders
/// leaves the top folder's own time old. shortcut: a bigger tree is sampled in listing order, and the live-process check still guards it.
func newestModification(in url: URL, limit: Int = 5000) -> Date? {
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    var newest = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return newest }
    var seen = 0
    for case let item as URL in walk {
        seen += 1
        if seen > limit { break }
        if let d = (try? item.resourceValues(forKeys: Set(keys)))?.contentModificationDate, d > newest ?? .distantPast { newest = d }
    }
    return newest
}

func runnersCleanInventory(engine: Bool) -> RunnerCleanInventory {
    let state = runnerStore.state(), active = runnerStore.helperActive()
    // state.json may be stale when the helper is off; a name in it is still treated as running.
    let running = Set(state.running)
    let runningRepos = Set((active ? (state.runningRepos ?? []) : []).map { $0.lowercased() })
    var items: [RunnerCleanItem] = []
    func created(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }
    func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    let workFolders = children(runnerStore.workDirectory)
    let cwds = workFolders.isEmpty ? [] : processDirectories()
    if cwds == nil { err("Could not list running processes, so every leftover job folder is treated as busy and skipped.") }
    for url in workFolders {
        let touched = [created(url), newestModification(in: url)].compactMap { $0 }.max()
        let busy = RunnerCleanRules.folderBusy(path: url.path, running: running, touched: touched, now: Date(), grace: leftoverGrace,
                                               processDirectories: cwds)
        items.append(.init(tier: .leftovers, kind: .folder, ref: url.path, bytes: RunnerStore.diskBytes(url), busy: busy))
    }
    for url in children(runnerStore.directory) {
        let name = url.lastPathComponent
        if name.hasPrefix(".download-") {
            let pid = Int32(name.dropFirst(".download-".count))
            items.append(.init(tier: .leftovers, kind: .folder, ref: url.path, bytes: RunnerStore.diskBytes(url), busy: pid.map(pidAlive) ?? true))
        }
    }
    for url in children(runnerStore.logDirectory) {
        let name = url.lastPathComponent
        items.append(.init(tier: .logs, kind: .folder, ref: url.path, bytes: RunnerStore.diskBytes(url), lastUsed: modified(url),
                           busy: running.contains((name as NSString).deletingPathExtension)))
    }
    for url in runnerStore.installDirectories {
        items.append(.init(tier: .runnerDownloads, kind: .folder, ref: url.path, bytes: RunnerStore.diskBytes(url),
                           version: String(url.lastPathComponent.dropFirst("macos-runner-".count))))
    }
    if engine {
        let filters = #"{"name":["noodle-linux-"],"status":["exited","dead"]}"#
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        for c in dockerJSON("/containers/json?all=1&filters=\(filters)") as? [[String: Any]] ?? [] {
            guard let name = (c["Names"] as? [String])?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  name.hasPrefix("noodle-linux-"),
                  RunnerCleanRules.containerCandidate(name: name, status: c["State"] as? String ?? "", running: running) else { continue }
            items.append(.init(tier: .leftovers, kind: .container, ref: name))
        }
        for v in runnerCacheVolumes() ?? [] {
            guard let repo = v.repo else { continue }
            // Last use is the repo's last job; with no record it is unknown, never the volume's age.
            items.append(.init(tier: .repoCaches, kind: .volume, ref: v.name, bytes: v.bytes ?? 0, lastUsed: state.lastJobs[repo]?.at, repo: repo))
        }
        let used = (dockerJSON("/containers/json?all=1") as? [[String: Any]]).map { Set($0.compactMap { $0["ImageID"] as? String }) }
        let images = (dockerJSON("/images/json") as? [[String: Any]] ?? []).map { i in
            (id: i["Id"] as? String ?? "", tags: i["RepoTags"] as? [String] ?? [], bytes: (i["Size"] as? NSNumber)?.int64Value ?? 0,
             created: (i["Created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        items += RunnerCleanRules.runnerImageItems(images, repository: imageRepository, usedIDs: used)
    }
    return RunnerCleanInventory(root: runnerStore.directory, items: items, busyRepos: runningRepos,
                                allReposBusy: active && !state.running.isEmpty && state.runningRepos == nil)
}

/// The helper saves state once per tick and right after each start: read it again just before deleting anything.
private func stillFree(_ item: RunnerCleanItem) -> Bool {
    let state = runnerStore.state()
    switch item.kind {
    case .volume: return item.repo.map { RunnerCache.clearRefusal(repo: $0, state: state, helperActive: runnerStore.helperActive()) == nil } ?? true
    case .container, .folder: return !state.running.contains((item.ref as NSString).lastPathComponent.replacingOccurrences(of: ".log", with: ""))
    case .image: return true
    }
}

private func removeExternal(_ item: RunnerCleanItem) -> Bool {
    guard let docker = which("docker") else { return false }
    let verb = item.kind == .container ? ["rm"] : item.kind == .volume ? ["volume", "rm"] : ["rmi"]
    return runWithTimeout(docker, verb + [item.ref], environment: engineDockerEnvironment, timeout: 60, errorOutput: FileHandle.nullDevice).code == 0
}

/// Working directories of every process this user can see, from one `lsof` call.
private func processDirectories() -> [String]? { processWorkingDirectories()?.map(\.path) }

/// Each process with its working directory, or nil when `lsof` could not list them.
func processWorkingDirectories() -> [(pid: Int32, path: String)]? {
    let r = runWithTimeout("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn"], timeout: 10, errorOutput: FileHandle.nullDevice)
    return RunnerCleanRules.processDirectories(lsofOutput: r.out, code: r.code, ownPID: getpid())
}

func runnersClean(dryRun: Bool, json: Bool, days: Int) {
    let engine = ping()
    let inventory = runnersCleanInventory(engine: engine)
    let plan = RunnerCleanPlanner.plan(inventory, .init(olderThanDays: days))
    let (done, failed, busy) = RunnerCleanRules.execute(plan, root: inventory.root, dryRun: dryRun, stillFree: stillFree, external: removeExternal)
    let skipped = plan.skipped + busy
    // macOS jobs run as the user, so their build output lands in the user's own folders. Reported, never deleted.
    let derived = URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let size: (Int64) -> String = { RunnerStore.sizeText($0) }
    // Only when macOS runners are in use, and the walk stops early: DerivedData can hold millions of files.
    let derivedBytes = runnerStore.repos().contains { $0.macos } && FileManager.default.fileExists(atPath: derived.path)
        ? Optional(RunnerStore.diskBytes(derived, maxEntries: 200_000)) : nil
    let left = derivedBytes.map {
        ["~/Library/Developer/Xcode/DerivedData (\($0.map(size) ?? "size unknown")): macOS jobs may write here. Noodle leaves it alone."]
    } ?? []
    let report = RunnerCleanReport(dryRun: dryRun, engine: engine, deleted: done, skipped: skipped, failed: failed, leftAlone: left)
    if json {
        jsonOut(encodableJSON(report))
        if !failed.isEmpty { exit(1) }
        return
    }
    if !engine { note("The Noodle engine is not running, so containers, cache volumes and images were not checked. Run `noodle start`.") }
    for t in report.tiers {
        out("\(t.tier). \(t.title): \(dryRun ? "would free" : "freed") \(size(t.bytes)) (\(t.items) item\(t.items == 1 ? "" : "s"))")
    }
    for s in skipped where s.reason != "last use unknown" && s.reason != "current runner version" && !s.reason.hasPrefix("used within") {
        out("Skipped \(s.item.repo ?? s.item.ref): \(s.reason)")
    }
    for s in failed { out("Could not remove \(s.item.ref)") }
    out("\(dryRun ? "Would free" : "Freed") \(size(report.totalBytes)) in total.")
    left.forEach { out($0) }
    if !failed.isEmpty { exit(1) }
}
