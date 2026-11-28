import Foundation
import NoodleCore

// noodle runners list, pause, resume and cache: repo list edits and disk use. Only the CLI writes; the app reads.

func runnersList(json: Bool = false) {
    let repos: [RunnerRepo]
    do { repos = try runnerStore.loadRepos() } catch { die(error.localizedDescription) }
    if json {
        let state = runnerStore.state(), on = runnerStore.helperActive()
        jsonOut(runnersListJSON(repos.map { r in
            RunnerRepoRow(repo: r.repo, kinds: r.kinds.map(\.rawValue).joined(separator: "+"),
                          mode: !r.isEnabled ? "paused" : on ? "on" : "off",
                          lastJob: state.lastJobs[r.repo].map { ($0.name, $0.conclusion, $0.url) })
        }, hold: on ? state.hold : nil, startFailures: on ? RunnerStartFailure.active(state.startFailures) : []))
        return
    }
    guard !repos.isEmpty else { out("No repos. Add one with `noodle runners add <owner/repo>`."); return }
    let state = runnerStore.state(), on = runnerStore.helperActive()
    if on, let hold = state.hold { out(hold) }
    if on { for f in RunnerStartFailure.active(state.startFailures) { out(f.line(logDirectory: runnerStore.logDirectory)) } }
    for r in repos {
        let last = state.lastJobs[r.repo].map { "\($0.name) \($0.conclusion ?? "ran") \($0.url)" } ?? "none"
        let mode = !r.isEnabled ? "paused" : on ? "on" : "off"
        out("\(r.repo)  \(r.kinds.map(\.rawValue).joined(separator: "+"))  \(mode)  last job: \(last)")
    }
}

func runnersSetEnabled(_ repo: String, _ enabled: Bool) {
    let stored: String?
    do {
        stored = try runnerStore.updateRepos { repos in
            guard let i = repos.firstIndex(where: { $0.repo.lowercased() == repo.lowercased() }) else { return nil }
            repos[i].enabled = enabled ? nil : false
            return repos[i].repo
        }
    } catch { die(error is RunnerStoreError ? error.localizedDescription : "cannot save: " + error.localizedDescription) }
    guard let stored else { die("\(repo) is not in the list") }
    // A paused repo keeps a job already running; it just gets no new runners.
    out(enabled ? "Resumed \(stored)" : "Paused \(stored). A job already running finishes.")
}

/// Removes a repo's cache volume through the docker CLI. Nil on success, else the error text.
func runnersRemoveCache(_ repo: String) -> String? {
    guard let docker = which("docker") else { return "docker CLI not found" }
    let errors = Pipe()
    let r = runWithTimeout(docker, ["volume", "rm", RunnerCache.volume(repo: repo)], environment: engineDockerEnvironment, timeout: 20,
                   errorOutput: errors.fileHandleForWriting)
    try? errors.fileHandleForWriting.close()
    let text = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
    return r.code == 0 ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runnersCacheClear(_ repo: String) {
    guard ping() else { engineDownDie("the Noodle engine is not running. Run `noodle start` first.") }
    // Checked last, right before the removal: a job may start while the engine is asked.
    if let why = RunnerCache.clearRefusal(repo: repo, state: runnerStore.state(), helperActive: runnerStore.helperActive()) { die(why) }
    if let error = runnersRemoveCache(repo) { die("cannot clear \(repo): \(error)") }
    out("Cleared the cache of \(repo)")
}

/// Runner cache volumes from the engine's `/system/df`, or nil when it did not answer. A missing or negative size is unknown.
func runnerCacheVolumes() -> [(name: String, repo: String?, bytes: Int64?)]? {
    guard let df = httpGet("/system/df", timeoutSeconds: 60), df.status == 200 else { return nil }
    let o = (try? JSONSerialization.jsonObject(with: df.body)) as? [String: Any]
    return (o?["Volumes"] as? [[String: Any]] ?? []).compactMap { v in
        guard let name = v["Name"] as? String, name.hasPrefix(RunnerCache.prefix) else { return nil }
        let size = ((v["UsageData"] as? [String: Any])?["Size"] as? NSNumber)?.int64Value
        return (name, RunnerCache.repo(fromVolume: name), size.flatMap { $0 < 0 ? nil : $0 })
    }
}

private func cacheReport() -> RunnerCacheReport {
    let found = ping() ? runnerCacheVolumes() : nil
    let volumes = (found ?? []).map { RunnerCacheReport.Volume(repo: $0.repo, volume: $0.name, bytes: $0.bytes) }
    return RunnerCacheReport(engine: found != nil, volumes: volumes,
                             installBytes: runnerStore.installDirectories.reduce(0) { $0 + RunnerStore.diskBytes($1) },
                             logsBytes: RunnerStore.diskBytes(runnerStore.logDirectory))
}

func runnersCache(json: Bool) {
    let report = cacheReport()
    if json {
        // Pretty-printed on purpose: tests/runners.sh matches `"engine" : false`.
        out(jsonLine(encodableJSON(report), pretty: true))
        return
    }
    func size(_ b: Int64?) -> String { b.map(RunnerStore.sizeText) ?? "unknown" }
    if !report.engine { out("The Noodle engine is not running, so cache volumes are not listed. Run `noodle start`.") }
    else if report.volumes.isEmpty { out("No cache volumes yet.") }
    for v in report.volumes { out("\(v.repo ?? v.volume)  \(size(v.bytes))  \(v.volume)") }
    out("macOS runner install  \(size(report.installBytes))")
    out("Logs  \(size(report.logsBytes))")
}
