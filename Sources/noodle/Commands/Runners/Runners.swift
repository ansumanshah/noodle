import Foundation
import NoodleCore

// noodle runners: GitHub Actions runners on this Mac.
// The CLI starts a detached helper that polls GitHub only while it is on. noodled has no part in this.

let runnerStore = RunnerStore(paths: paths)
let runnersUsage = "usage: noodle runners add [owner/repo] [--macos] [--allow-public] | remove <owner/repo> | list [--json] | pause <owner/repo> | resume <owner/repo> | cache [--json] | cache clear <owner/repo> | clean [--dry-run] [--older-than DAYS] [--json] | repos [--json] | check <owner/repo> [--json] | doctor [--json] | toolchains [--json] | start | stop | status [--json]"

/// No arguments, or only `--json`; anything else is a usage error.
private func onlyJSONFlag(_ rest: [String]) -> Bool {
    guard rest.isEmpty || rest == ["--json"] else { die(runnersUsage, code: 2) }
    return !rest.isEmpty
}

func cmdRunners(_ args: [String]) {
    var rest = Array(args.dropFirst())
    let json = ["list", "repos", "check", "status"].contains(args.first ?? "") && rest.contains("--json")
    if json { rest.removeAll { $0 == "--json" } }
    switch args.first {
    case "add":
        // No repo named: the GitHub repo of the current folder.
        let positional = rest.filter { !$0.hasPrefix("-") }
        let named = positional.first
        let flags = Set(rest.filter { $0.hasPrefix("--") })
        guard positional.count <= 1, flags.isSubset(of: ["--macos", "--allow-public"]), flags.count == rest.count - positional.count else {
            die(runnersUsage, code: 2)
        }
        guard let repo = named ?? currentRepo() else { die("this folder has no GitHub remote. Run `noodle runners add <owner/repo>`.", code: 2) }
        guard RunnerStore.validRepo(repo) else { die(runnersUsage, code: 2) }
        runnersAdd(repo, macos: flags.contains("--macos"), allowPublic: flags.contains("--allow-public"))
    case "remove":
        guard rest.count == 1, RunnerStore.validRepo(rest[0]) else { die(runnersUsage, code: 2) }
        let removed: RunnerRepo?
        do {
            removed = try runnerStore.updateRepos { repos in
                repos.firstIndex { $0.repo.lowercased() == rest[0].lowercased() }.map { repos.remove(at: $0) }
            }
        } catch { die(error is RunnerStoreError ? error.localizedDescription : "cannot save: " + error.localizedDescription) }
        guard let removed else { die("\(rest[0]) is not in the list") }
        // The volume is named after the stored spelling, and a running job of this repo may be using it.
        if RunnerCache.clearRefusal(repo: removed.repo, state: runnerStore.state(), helperActive: runnerStore.helperActive()) != nil {
            out("Removed \(removed.repo). Its cache stays because a job of this repo is running; "
                + "run `noodle runners cache clear \(removed.repo)` after the job ends.")
            return
        }
        _ = runnersRemoveCache(removed.repo)
        out("Removed \(removed.repo)")
    case "list":
        guard rest.isEmpty else { die(runnersUsage, code: 2) }
        runnersList(json: json)
    case "pause", "resume":
        guard rest.count == 1, RunnerStore.validRepo(rest[0]) else { die(runnersUsage, code: 2) }
        runnersSetEnabled(rest[0], args[0] == "resume")
    case "cache":
        if rest.first == "clear" {
            guard rest.count == 2, RunnerStore.validRepo(rest[1]) else { die(runnersUsage, code: 2) }
            runnersCacheClear(rest[1])
        } else {
            runnersCache(json: onlyJSONFlag(rest))
        }
    case "clean":
        let o = runnersCleanArgs(rest)
        runnersClean(dryRun: o.dryRun, json: o.json, days: o.days)
    case "repos":
        guard rest.isEmpty else { die(runnersUsage, code: 2) }
        runnersRepos(json: json)
    case "check":
        guard rest.count == 1, RunnerStore.validRepo(rest[0]) else { die(runnersUsage, code: 2) }
        runnersCheck(rest[0], json: json)
    case "doctor":
        runnersDoctor(json: onlyJSONFlag(rest))
    case "start":
        guard rest.isEmpty else { die(runnersUsage, code: 2) }
        runnersStart()
    case "stop":
        guard rest.isEmpty else { die(runnersUsage, code: 2) }
        runnersStop()
    case "status":
        guard rest.isEmpty else { die(runnersUsage, code: 2) }
        runnersStatus(json: json)
    case "toolchains":
        runnersToolchains(json: onlyJSONFlag(rest))
    case "_watch": runnersWatch()
    default: die(runnersUsage, code: 2)
    }
}

/// On a public repo a pull request from a fork can start a job. A macOS job runs as you on this Mac; a Linux job
/// gets Noodle's Docker engine, so it can reach every container and volume.
private func refusePublic(_ repo: String, macos: Bool, token: String?) {
    let api = GitHubRunnersAPI { token }
    let isPrivate = try? blocking { try await api.isPrivate(repo) }
    guard isPrivate != true else { return }
    let risk = macos ? "run code on this Mac as you, outside any sandbox"
        : "run code with full access to Noodle's Docker engine, including every container and volume"
    die("""
        \(repo) is \(isPrivate == nil ? "not confirmed private (sign in so Noodle can check)" : "a public repo"). \
        A pull request from a fork can \(risk). Pass --allow-public only if you accept that.
        """)
}

private func runnersAdd(_ repo: String, macos: Bool, allowPublic: Bool) {
    // Asked once for the whole command: each ask runs git and maybe a keychain prompt.
    let token = GitHubToken.fill()
    if !allowPublic { refusePublic(repo, macos: macos, token: token) }
    do {
        try runnerStore.updateRepos { repos in
            if let i = repos.firstIndex(where: { $0.repo.lowercased() == repo.lowercased() }) {
                repos[i].macos = repos[i].macos || macos
                if allowPublic { repos[i].allowPublic = true }
            } else { repos.append(RunnerRepo(repo: repo, macos: macos, allowPublic: allowPublic ? true : nil)) }
        }
    } catch { die(error is RunnerStoreError ? error.localizedDescription : "cannot save: " + error.localizedDescription) }
    out("Added \(repo). Use runs-on: [self-hosted, noodle] for Linux jobs." + (macos ? " Use [self-hosted, noodle-macos] for macOS jobs." : ""))
    if macos {
        note("Warning: a macOS job runs directly on this Mac as you, in a fresh folder that is deleted afterwards. It is not a sandbox. A workflow can read your files, so enable this only for repos you trust.")
    }
    if runnerStore.helperActive() { return }
    if token != nil { runnersStart(signedIn: true) } else { out("Runners are off. Sign in to GitHub, then run `noodle runners start`.") }
}

/// `owner/repo` of the current folder's `origin`, when it is on GitHub.
private func currentRepo() -> String? {
    guard let git = which("git") else { return nil }
    return RunnerStore.repo(fromRemote: runWithTimeout(git, ["remote", "get-url", "origin"], environment: env, timeout: 5).out)
}

/// Repos you can add, one per line, for the app's picker and for scripts.
private func runnersRepos(json: Bool) {
    guard let token = GitHubToken.fill() else { die("no GitHub sign-in found. Sign in under Settings first.") }
    let api = GitHubRunnersAPI { token }
    do {
        let repos = try blocking({ try await api.adminRepos().map { ($0.repo, $0.isPrivate) } })
        if json { jsonOut(runnersReposJSON(repos.map { (repo: $0.0, isPrivate: $0.1) })); return }
        for r in repos { out("\(r.0)\t\(r.1 ? "private" : "public")") }
    } catch { die("cannot list repos: \(error.localizedDescription)") }
}

private func runnersStatus(json: Bool) {
    let state = runnerStore.state()
    if json {
        let on = runnerStore.helperActive()
        jsonOut(runnersStatusJSON(on: on, repos: runnerStore.repos().count, running: on ? state.running : [], awake: on && state.awake,
                                  message: state.message, hold: on ? state.hold : nil,
                                  startFailures: on ? RunnerStartFailure.active(state.startFailures) : []))
        return
    }
    guard runnerStore.helperActive() else {
        out("Runners off" + (state.message.map { ": \($0)" } ?? ""))
        return
    }
    out("Runners on, \(runnerStore.repos().count) repo(s), \(state.running.count) runner(s) alive" + (state.running.isEmpty ? "" : ": " + state.running.joined(separator: ", ")))
    if let hold = state.hold { out(hold) }
    for f in RunnerStartFailure.active(state.startFailures) { out(f.line(logDirectory: runnerStore.logDirectory)) }
    if state.awake { out("Keeping this Mac awake while a job runs") }
    if let m = state.message { out(m) }
    if let line = toolchainStatusLine() { out(line) }
}

private func runnersStart(signedIn: Bool = false) {
    let repos: [RunnerRepo]
    do { repos = try runnerStore.loadRepos() } catch { die(error.localizedDescription) }
    guard !repos.isEmpty else { die("no repos yet. Run `noodle runners add <owner/repo>` first.") }
    guard signedIn || GitHubToken.fill() != nil else {
        die("no GitHub sign-in found. Sign in under Settings, turn on \"Also use for git clone and runners\" so the token has the repo scope, then run this again.")
    }
    if runnerStore.helperActive() { out("Already on"); return }
    try? FileManager.default.removeItem(at: runnerStore.stopMarker)
    let program = Bundle.main.executableURL?.path ?? selfDirectory() + "/noodle"
    // A login item, so runners come back after a restart and after a crash. Without launchctl (tests), a plain child.
    if !(launchctlAllowed && runnersInstallAgent(program: program)) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = ["runners", "_watch"]
        process.environment = env
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { die("cannot start runners: \(error.localizedDescription)") }
    }
    guard waitFor({ runnerStore.helperActive() }, seconds: 5) else { die("runners did not start; run `noodle runners start` to retry") }
    out("Runners on")
}

let runnersAgentLabel = "dev.getnoodle.runners"
var runnersAgentPlist: URL { URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(runnersAgentLabel).plist") }

/// Runs at login and again if the helper crashes; a clean stop exits 0, which launchd leaves alone.
private func runnersInstallAgent(program: String) -> Bool {
    // launchd's bare PATH has no docker or git, and the Mac app passes only the system folders.
    var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"] where !path.contains(dir) { path.append(dir) }
    var variables = ["PATH": path.joined(separator: ":")]
    if env["NOODLE_HOME"]?.isEmpty == false { variables["NOODLE_HOME"] = paths.root.path }
    let plist: [String: Any] = [
        "Label": runnersAgentLabel, "ProgramArguments": [program, "runners", "_watch"],
        "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Background",
        "AssociatedBundleIdentifiers": ["dev.getnoodle.Noodle"],  // System Settings shows the Noodle name and icon
        "EnvironmentVariables": variables,
        "StandardErrorPath": runnerStore.directory.appendingPathComponent("helper.log").path,
    ]
    do {
        try FileManager.default.createDirectory(at: runnersAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: runnersAgentPlist, options: .atomic)
    } catch { return false }
    _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(runnersAgentLabel)"])
    return run("/bin/launchctl", ["bootstrap", "gui/\(uid)", runnersAgentPlist.path]).code == 0
}

/// Off stays off after a restart.
func runnersRemoveAgent() {
    if launchctlAllowed { _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(runnersAgentLabel)"]) }
    try? FileManager.default.removeItem(at: runnersAgentPlist)
}

private func runnersStop() {
    defer { runnersRemoveAgent() }
    guard runnerStore.helperActive() else { out("Already off"); return }
    do { try Data().write(to: runnerStore.stopMarker) } catch { die("cannot stop runners: \(error.localizedDescription)") }
    // Idle runners are ended and a job in progress is cancelled; the helper needs a few seconds to clean up.
    guard waitFor({ !runnerStore.helperActive() }, seconds: 60) else {
        runnersRemoveAgent()  // die() exits, so the defer would not run
        die("runners did not stop within a minute; jobs may still be running. Run `noodle runners start`, then `noodle runners stop`, to clean up.")
    }
    out("Runners off")
}
