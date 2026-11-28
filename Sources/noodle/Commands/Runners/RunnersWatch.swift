import Darwin
import Foundation
import NoodleCore

/// The sign-in, asked for once. A failed ask is remembered until the next tick, so one tick never waits on git twice.
private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?, tried = false
    func current() -> String? {
        if let known = lock.withLock({ tried ? .some(token) : nil }) { return known }
        let filled = GitHubToken.fill()  // outside the lock: it can take up to 15 s
        return lock.withLock { if !tried { token = filled; tried = true }; return token }
    }
    func forget() { lock.withLock { token = nil; tried = false } }
    /// Once per tick: a missing sign-in is asked for again.
    func retryIfMissing() { lock.withLock { if token == nil { tried = false } } }
}

// @unchecked: the watch loop owns each child; endAll hands each one to exactly one thread while the loop waits.
private final class RunnerChild: @unchecked Sendable {
    let name: String, repo: String, kind: RunnerKind, process: Process, started = RunnerClock.now(), startedAt = Date(), directory: URL?
    var runnerID: Int?
    /// True when the helper ended this runner itself, which is never a failed start.
    var stopped = false
    /// True once end() ran, so a runner is cleaned up and unregistered exactly once.
    var ended = false
    /// GitHub listed it online and not busy at the last poll. Only runners with a job keep the Mac awake.
    var idle = false
    /// Deleted on GitHub while unused: there is no job to look up when it is reaped.
    var unused = false
    /// The last attempt to end it while its repo is not polled, and since when GitHub has refused those attempts.
    var lastEndTry = -TimeInterval.infinity, refusedSince: TimeInterval?
    var live: Bool { process.isRunning && !ended }
    init(name: String, repo: String, kind: RunnerKind, process: Process, directory: URL?) {
        self.name = name; self.repo = repo; self.kind = kind; self.process = process; self.directory = directory
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var set: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The helper ends a runner 6 h after the runner started (GitHub ends a job after 6 h of the job): counted from the
/// start, so a runner that idled 4 min before its job ends that job at 5 h 56 min. An unused runner goes after 5 min.
/// For 5 min after a job, one runner per repo and kind waits ready, so the next push starts at once instead of after
/// a poll and a boot.
private let jobTimeout: TimeInterval = 6 * 3600, idleTimeout: TimeInterval = 300

/// The last line a runner wrote, shown when runners keep failing.
private func lastLogLine(_ child: RunnerChild) -> String? {
    let record = RunnerJobRecord(repo: child.repo, name: "", url: "", conclusion: nil, at: Date(), kind: child.kind, seconds: 0,
                                 log: child.name + ".log")
    return runnerStore.logTail(for: record).flatMap(RunnerStartFailure.lastLine(of:))
}

/// GitHub's pinned osx-arm64 runner, downloaded once and checked against its SHA-256.
private func macRunnerInstall() throws -> URL {
    let fm = FileManager.default
    let install = runnerStore.directory.appendingPathComponent("macos-runner-\(RunnerPin.version)", isDirectory: true)
    if fm.isExecutableFile(atPath: install.appendingPathComponent("run.sh").path) { return install }
    try? fm.removeItem(at: install)  // a partial install would make the move below fail forever
    let work = runnerStore.directory.appendingPathComponent(".download-\(getpid())", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let archive = work.appendingPathComponent(RunnerPin.file)
    let curl = try MacRunnerDownload.shared.live()
    let r = try downloadTool(["--fail", "--silent", "--show-error", "--location", "--connect-timeout", "15", "--max-time", "600",
                              "--retry", "3", "--output", archive.path, RunnerPin.url], child: curl, handleSignals: false)
    guard r.code == 0 else { throw NSError(domain: "runners", code: 1, userInfo: [NSLocalizedDescriptionKey: "download failed (curl \(r.code))"]) }
    guard (try? Digest.sha256(file: archive)) == "sha256:" + RunnerPin.sha256 else {
        throw NSError(domain: "runners", code: 2, userInfo: [NSLocalizedDescriptionKey: "SHA-256 mismatch for \(RunnerPin.file); discarded"])
    }
    let tar = try MacRunnerDownload.shared.live()  // a stop during the checksum must not start the unpack, and one during it ends tar
    let unpacked = work.appendingPathComponent("x", isDirectory: true)
    try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
    guard try tar.run(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", unpacked.path]).code == 0 else {
        throw NSError(domain: "runners", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot unpack the runner"])
    }
    try fm.moveItem(at: unpacked, to: install)
    return install
}

/// The macOS runner download, on its own thread: it can take minutes, and the tick and a shutdown must not wait for it.
/// A helper that exits mid-download leaves a `.download-` folder, which the next start sweeps.
private final class MacRunnerDownload: @unchecked Sendable {
    static let shared = MacRunnerDownload()
    struct Pending: Error {}
    private let lock = NSLock()
    private var running = false, failure: Error?, cancelled = false, curl: ToolDownloadProcess?

    /// A fresh curl handle for the next step, or a throw once `cancel()` ran.
    func live() throws -> ToolDownloadProcess {
        try lock.withLock {
            if cancelled { throw NSError(domain: "runners", code: 4, userInfo: [NSLocalizedDescriptionKey: "download cancelled"]) }
            let p = ToolDownloadProcess(); curl = p; return p
        }
    }

    /// Stop requested: kills curl's process group, and later steps throw.
    func cancel() {
        let p = lock.withLock { cancelled = true; return curl }
        p?.cancel(SIGTERM)
    }

    /// Returns when the runner is in place. Otherwise starts the download, if none runs, and throws `Pending`; the
    /// failure of the last download is thrown once, so the crash guard paces the next try.
    func ready() throws {
        let installed = runnerStore.directory.appendingPathComponent("macos-runner-\(RunnerPin.version)/run.sh").path
        if FileManager.default.isExecutableFile(atPath: installed) { return }
        try lock.withLock {
            if running { throw Pending() }
            if let failure { self.failure = nil; throw failure }
            running = true
        }
        Thread.detachNewThread {
            let result = Result { _ = try macRunnerInstall() }
            self.lock.withLock { self.running = false; if case .failure(let e) = result { self.failure = e } }
        }
        throw Pending()
    }
}

/// Checks that a runner of this kind can start, before a JIT config is requested and an orphan runner registered.
private func preflight(_ kind: RunnerKind) throws {
    switch kind {
    case .linux:
        guard which("docker") != nil else { throw NSError(domain: "runners", code: 4, userInfo: [NSLocalizedDescriptionKey: "docker CLI not found"]) }
    case .macos: try MacRunnerDownload.shared.ready()
    }
}

/// A crashed helper leaves work folders, half downloads and containers behind; clear them once the lock is ours.
private func sweep() {
    let fm = FileManager.default
    let work = (try? fm.contentsOfDirectory(at: runnerStore.workDirectory, includingPropertiesForKeys: nil)) ?? []
    let processes = work.isEmpty ? [] : processWorkingDirectories()
    for url in work {
        // Noodle never makes a link here: remove the link alone, never touch what it points to.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { try? fm.removeItem(at: url); continue }
        // A macOS job orphaned by a crashed helper may still run in its folder: end it first, or keep the folder.
        guard stopProcesses(inWorkFolder: url.lastPathComponent, processes: processes) else { continue }
        try? fm.removeItem(at: url)
    }
    for url in (try? fm.contentsOfDirectory(at: runnerStore.directory, includingPropertiesForKeys: nil)) ?? []
    where url.lastPathComponent.hasPrefix(".download-") { try? fm.removeItem(at: url) }
    guard let docker = which("docker") else { return }
    // The name filter is an unanchored regex, and with the engine down the output is an error message, not names.
    let listed = runWithTimeout(docker, ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=" + RunnerKind.linux.prefix],
                        environment: engineDockerEnvironment, timeout: 20, errorOutput: FileHandle.nullDevice)
    guard listed.code == 0 else { return }
    let ids = listed.out.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix(RunnerKind.linux.prefix) }
    if !ids.isEmpty { _ = runWithTimeout(docker, ["rm", "-f"] + ids, environment: engineDockerEnvironment, timeout: 30) }
}

private func spawn(_ kind: RunnerKind, repo: String, name: String, jit: String) throws -> RunnerChild {
    let fm = FileManager.default
    try fm.createDirectory(at: runnerStore.logDirectory, withIntermediateDirectories: true)
    let log = runnerStore.logDirectory.appendingPathComponent(name + ".log")
    fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }  // the child holds its own copy
    let p = Process()
    let stdin: Pipe? = kind == .linux ? Pipe() : nil
    p.standardInput = FileHandle.nullDevice; p.standardOutput = handle; p.standardError = handle
    var directory: URL?
    switch kind {
    case .linux:
        guard let docker = which("docker") else { throw NSError(domain: "runners", code: 4, userInfo: [NSLocalizedDescriptionKey: "docker CLI not found"]) }
        p.executableURL = URL(fileURLWithPath: docker)
        p.arguments = RunnerPin.dockerArguments(name: name, repo: repo)
        p.environment = engineDockerEnvironment
        if let stdin { p.standardInput = stdin }
    case .macos:
        recordToolchainsInBackground()
        let install = try macRunnerInstall()
        let dir = runnerStore.workDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: runnerStore.workDirectory, withIntermediateDirectories: true)
        // APFS clone: a fresh copy per job costs almost nothing, and deleting it leaves nothing behind.
        guard run("/bin/cp", ["-c", "-R", install.path, dir.path]).code == 0 else {
            throw NSError(domain: "runners", code: 5, userInfo: [NSLocalizedDescriptionKey: "cannot prepare a work folder"])
        }
        directory = dir
        p.executableURL = dir.appendingPathComponent("run.sh")
        p.currentDirectoryURL = dir
        // A clean environment: nothing the helper holds reaches the job.
        p.environment = ["HOME": home, "USER": NSUserName(), "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
                         "PATH": macJobPath,
                         // GitHub's runner reads the single-use JIT config only from here, so it stays in run.sh's
                         // environment for the job's lifetime and any process running as this user can read it.
                         "ACTIONS_RUNNER_INPUT_JITCONFIG": jit]
    }
    do { try p.run() } catch { try? directory.map(fm.removeItem(at:)); throw error }
    if let stdin {
        // The config goes over a pipe, not argv or the environment, so `ps` and `docker inspect` never show it.
        try? stdin.fileHandleForWriting.write(contentsOf: Data((jit + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
    }
    return RunnerChild(name: name, repo: repo, kind: kind, process: p, directory: directory)
}

/// `pid` and all its descendants, parents first. A macOS job's Runner.Listener, Runner.Worker and build tools are
/// children of run.sh in the helper's own process group, so killpg is no option.
private func processTree(_ pid: Int32) -> [Int32] {
    guard RunnerCleanRules.signalable(pid, ownPID: getpid()) else { return [] }
    let kids = runWithTimeout("/usr/bin/pgrep", ["-P", String(pid)], timeout: 5).out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    return [pid] + kids.flatMap(processTree)
}

/// Ends every process working inside the work folder `name`. False, with a line in the helper log, when the
/// process list is unknown or one survived: the folder must stay then.
private func stopProcesses(inWorkFolder name: String, processes: [(pid: Int32, path: String)]?) -> Bool {
    guard let processes else { err("runners: kept work folder \(name): could not list running processes"); return false }
    let pids = RunnerCleanRules.pids(inWorkFolder: name, workDirectory: runnerStore.workDirectory.path, processes: processes)
    let tree = pids.flatMap(processTree)
    if tree.isEmpty || stopTree(tree) { return true }
    err("runners: kept work folder \(name): a process in it did not stop")
    return false
}

private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// SIGTERM to every process, up to 10 s to exit, then SIGKILL. True when none is left.
private func stopTree(_ pids: [Int32], isRunning: () -> Bool = { false }) -> Bool {
    pids.forEach { kill($0, SIGTERM) }
    let until = RunnerClock.now() + 10
    while isRunning() || pids.contains(where: alive), RunnerClock.now() < until { Thread.sleep(forTimeInterval: 0.1) }
    let left = pids.filter(alive)
    left.forEach { kill($0, SIGKILL) }
    if !left.isEmpty { Thread.sleep(forTimeInterval: 0.2) }
    return !pids.contains(where: alive)
}

/// Stops the runner, removes its container and folder, and unregisters it so a runner that never took a job
/// does not linger offline on GitHub. `stopped: false` for the job limit, which is not a deliberate stop.
private func end(_ child: RunnerChild, api: GitHubRunnersAPI, stopped: Bool = true) {
    guard !child.ended else { return }
    child.ended = true
    if child.process.isRunning {
        child.stopped = stopped
        let pid = child.process.processIdentifier
        if child.kind == .macos {
            _ = stopTree(processTree(pid)) { child.process.isRunning }
        } else {
            child.process.terminate()
            let until = RunnerClock.now() + 10
            while child.process.isRunning, RunnerClock.now() < until { Thread.sleep(forTimeInterval: 0.1) }
            if child.process.isRunning { kill(pid, SIGKILL) }
        }
    }
    if child.kind == .linux, let docker = which("docker") { _ = runWithTimeout(docker, ["rm", "-f", child.name], environment: engineDockerEnvironment, timeout: 20) }
    // run.sh may be gone while a build it started still works in the folder.
    if let dir = child.directory, stopProcesses(inWorkFolder: dir.lastPathComponent, processes: processWorkingDirectories()) {
        try? FileManager.default.removeItem(at: dir)
    }
    if let id = child.runnerID { let repo = child.repo; _ = try? blocking { await api.deleteRunner(repo, id: id) } }
}

/// Ends a runner that should be idle, without racing a job: GitHub deletes it first, and refuses (false) when it is
/// running a job, so the runner is left alone. A runner without a known id cannot be checked and stays.
private func endUnused(_ child: RunnerChild, api: GitHubRunnersAPI) throws -> Bool {
    guard child.live, let id = child.runnerID else { return false }
    let repo = child.repo
    // Refused: it has a job, so it counts as busy for the rest of the tick (awake, cover).
    guard try blocking({ try await api.removeRunner(repo, id: id) }) else { child.idle = false; return false }
    child.runnerID = nil  // already gone on GitHub
    child.unused = true
    end(child, api: api)
    return true
}

/// Ends runners side by side, so `runners stop` is not waiting on one 10 s grace period after another.
private func endAll(_ children: [RunnerChild], api: GitHubRunnersAPI) {
    DispatchQueue.concurrentPerform(iterations: children.count) { end(children[$0], api: api) }
}

func runnersWatch() {
    _ = setsid()
    // docker may exit before it reads the JIT config from its stdin; the write must fail, not kill the helper.
    signal(SIGPIPE, SIG_IGN)
    guard let lock = runnerStore.acquireLock() else { return }
    defer { close(lock) }
    sweep()
    let fm = FileManager.default
    let terminated = StopFlag()
    let signalSources = stopSignals(terminated)
    // Keep the sources alive to the end: SIGTERM and SIGINT are ignored, so without them launchctl bootout needs SIGKILL.
    defer { signalSources.forEach { $0.cancel() } }
    let tokens = TokenCache()
    let api = GitHubRunnersAPI { tokens.current() }
    // Read again every few minutes, so a new or switched Xcode is seen without restarting the helper.
    var xcode = selectedXcodeMajor() ?? nil, xcodeReadAt = RunnerClock.now()
    var children: [RunnerChild] = []
    var backoff = RunnerBackoff(), resume = -TimeInterval.infinity, planner = RunnerPlanner()
    var lastJobEnd: [String: TimeInterval] = [:]  // RunnerClock, as every interval below
    var knownRepos: [RunnerRepo] = []
    var repoSkip: [String: (until: TimeInterval, message: String)] = [:]
    var health = RunnerHealthGate()
    var heldText: String?
    var state = RunnerState(), visibility = RunnerVisibility()
    let saved = runnerStore.state()
    state.lastJobs = saved.lastJobs; state.history = saved.history
    var crashes = RunnerCrashGuard(restoring: saved.startFailures)
    func publish(_ message: String?) {
        // A runner GitHub lists as idle has no job; any other, starting or not reported idle, counts.
        awake.update(activeJobs: children.filter { !$0.idle }.count)
        crashes.expire()
        state.startFailures = crashes.stored
        let next = state.publishing(message: message, running: children.map(\.name), runningRepos: children.map(\.repo),
                                    awake: awake.holding, hold: heldText)
        if next != state || !fm.fileExists(atPath: runnerStore.directory.appendingPathComponent("state.json").path) {
            state = next; runnerStore.saveState(state)
        }
    }
    func stopForSignIn() {
        endAll(children, api: api)
        children = []
        awake.update(activeJobs: 0)
        state.running = []; state.runningRepos = nil
        state.awake = false
        state.message = "Stopped: GitHub rejected the saved sign-in three times. Sign in again (the token needs the repo scope), then run `noodle runners start`."
        runnerStore.saveState(state)
    }
    let stopMarker = runnerStore.stopMarker.path
    let shouldStop: @Sendable () -> Bool = { terminated.set || FileManager.default.fileExists(atPath: stopMarker) }
    func stopping() -> Bool { shouldStop() }
    var message: String?
    let awake = AwakeGuard(api: IOKitAssertions())

    while !stopping() {
        tokens.retryIfMissing()
        // The job limit first, so the finished sweep below looks its job up in this tick.
        for child in children where child.live && RunnerClock.now() - child.started > jobTimeout {
            end(child, api: api, stopped: false)
        }
        // Finished runners: remove their folder, then note which job they took.
        // Children that exited, taken once so each is ended and counted exactly once, even if more die during the slow calls.
        // The age is taken now: end() and the job lookup below can take many seconds.
        reapFinished(&children, api: api, state: &state, lastJobEnd: &lastJobEnd, crashes: &crashes)
        // Runners count as busy until GitHub says idle in this tick. In a back-off or with no sign-in nothing is
        // polled, so the Mac stays awake rather than sleeping through a job it cannot see.
        children.forEach { $0.idle = false }
        if RunnerClock.now() >= resume, tokens.current() == nil {
            // Without a token private repos answer 404, which reads like a deleted repo.
            message = "No GitHub sign-in found. Sign in under Settings and turn on \"Also use for git clone and runners\"."
            heldText = nil  // nothing starts without a sign-in, so an old hold would only mislead
        } else if RunnerClock.now() >= resume {
            if RunnerClock.now() - xcodeReadAt > Toolchains.refreshSeconds {
                if let read = selectedXcodeMajor() { xcode = read }  // a failed read keeps the last answer
                xcodeReadAt = RunnerClock.now()
            }
            let hold = health.check(SystemRunnerHealth())
            heldText = hold?.text
            // One line per problem, in repo order, so the text does not flip between repos from tick to tick.
            var messages: [String] = []
            func note(_ m: String?) { if let m, !messages.contains(m) { messages.append(m) } }
            var gaveUp = false
            /// Notes a failed GitHub call. True when nothing more should be asked this tick.
            func failed(_ error: Error, repo: String) -> Bool {
                switch error {
                case RunnerAPIError.forbidden, RunnerAPIError.http:
                    // This repo only (no admin access, deleted, renamed, a 5xx): the others keep polling and their runners.
                    // Asked again after a minute, its message shown meanwhile.
                    let m = "\(repo): \(error.localizedDescription)"
                    note(m); repoSkip[repo] = (RunnerClock.now() + 60, m)
                    return false
                case let error as RunnerAPIError:
                    if error == .unauthorized { tokens.forget(); api.clearCaches() }
                    guard let wait = backoff.failure(error) else { gaveUp = true; return true }
                    if case .limited = error { note("GitHub is limiting requests; waiting \(Int(wait)) s") }
                    else if error == .unauthorized { note("GitHub did not accept the sign-in; retrying") }
                    else { note("\(repo): \(error.localizedDescription)") }
                    if wait > 10 || error == .unauthorized { resume = RunnerClock.now() + wait }
                    return true
                default:
                    note(error.localizedDescription)
                    return false
                }
            }
            // An unreadable list keeps the last good one, so a bad edit does not stop running repos.
            do { knownRepos = try runnerStore.loadRepos() } catch { note(error.localizedDescription) }
            api.keepCaches(repos: Set(knownRepos.filter(\.isEnabled).map(\.repo)))
            // Gather every repo first, then decide once for all of them.
            var demands: [RunnerDemand] = [], polled: [String: RunnerRepo] = [:]
            var aborted = false  // an account-wide failure (sign-in, rate limit, network): no deletes or starts this tick
            for repo in knownRepos where repo.isEnabled {
                if stopping() { break }
                if let skip = repoSkip[repo.repo], RunnerClock.now() < skip.until { note(skip.message); continue }
                repoSkip[repo.repo] = nil
                do {
                    let warm = Set(RunnerKind.allCases.filter {
                        lastJobEnd[repo.repo + "|" + $0.rawValue].map { RunnerClock.now() - $0 < idleTimeout } ?? false
                    })
                    demands += try gather(repo, api: api, xcode: xcode, warm: warm, crashes: crashes, children: children,
                                          visibility: visibility, note: note, stop: shouldStop)
                    polled[repo.repo] = repo
                    backoff.success()
                } catch { if failed(error, repo: repo.repo) { aborted = true; break } }
            }
            if gaveUp { stopForSignIn(); return }
            if !aborted { aborted = endUnpolled(children, polled: Set(polled.keys), api: api, stopping: stopping, failed: failed) }
            if !aborted, !stopping() {
                // Low disk or memory: start nothing new; queued jobs stay on GitHub and running jobs are left alone.
                if hold != nil { for i in demands.indices where demands[i].queued > 0 || demands[i].warm { demands[i].blocked = true } }
                let slots = children.filter(\.live).map {
                    RunnerSlot(name: $0.name, repo: $0.repo, kind: $0.kind, idle: $0.idle, age: RunnerClock.now() - $0.started)
                }
                var plan = RunnerTick.plan(demands, runners: slots, planner: &planner)
                aborted = checkVisibility(&plan, demands: demands, polled: polled, api: api, visibility: &visibility, planner: &planner,
                                          note: note, failed: failed)
                _ = RunnerTick.evict(&plan) { e in
                    guard !aborted, !stopping(), let child = children.first(where: { $0.name == e.name }) else { return false }
                    do { return try endUnused(child, api: api) } catch { if failed(error, repo: child.repo) { aborted = true }; return false }
                }
                for d in demands {
                    guard !aborted, let count = plan.starts[d.key], count > 0, polled[d.repo] != nil, !stopping() else { continue }
                    let before = children.count
                    defer { if children.count > before { planner.started(key: d.key) } }
                    do {
                        try start(count, d.kind, repo: d.repo, api: api, xcode: xcode, crashes: &crashes, children: &children, note: note,
                                  stopping: stopping) { kids in
                            // Not publish(): it reads `children` and `crashes`, which start holds inout.
                            var now = state; now.running = kids.map(\.name); now.runningRepos = kids.map(\.repo)
                            runnerStore.saveState(now)
                        }
                    } catch { if failed(error, repo: d.repo) { aborted = true } }
                }
            }
            if gaveUp { stopForSignIn(); return }
            reapUnused(&children, crashes: &crashes)
            message = messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        publish(message)
        let until = RunnerClock.now() + 10
        while RunnerClock.now() < until, !stopping() { Thread.sleep(forTimeInterval: 1) }
    }
    shutDown(children, api: api, awake: awake, state: &state)
}

/// SIGTERM and SIGINT set `terminated` instead of killing the helper, so its runners end cleanly.
private func stopSignals(_ terminated: StopFlag) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { terminated.set = true }
        source.resume()
        return source
    }
}

/// Finished runners: remove their folder, then note which job they took.
private func reapFinished(_ children: inout [RunnerChild], api: GitHubRunnersAPI, state: inout RunnerState,
                          lastJobEnd: inout [String: TimeInterval], crashes: inout RunnerCrashGuard) {
    let finished = children.filter { !$0.process.isRunning }.map { ($0, RunnerClock.now() - $0.started) }
    for (child, seconds) in finished {
        end(child, api: api)
        let (repoName, runnerName, since) = (child.repo, child.name, child.startedAt)
        var lookup = RunnerExit.Job.unknown
        // try? would flatten "no job" and "lookup failed" into one nil, so keep the Result.
        if case .success(let found) = Result(catching: { try blocking({ try await api.job(repoName, ranOn: runnerName, since: since) }) }) {
            lookup = found == nil ? .none : .took
            if let job = found {
                let at = Date()
                state.lastJobs[child.repo] = RunnerLastJob(name: job.name, url: job.url, conclusion: job.conclusion, at: at)
                state.record(RunnerJobRecord(repo: child.repo, name: job.name, url: job.url, conclusion: job.conclusion, at: at, kind: child.kind,
                                             seconds: job.seconds ?? Int(seconds), log: child.name + ".log"))
                lastJobEnd[child.repo + "|" + child.kind.rawValue] = RunnerClock.now()
            }
        }
        crashes.ended(RunnerExit(kind: child.kind, repo: child.repo, name: child.name, seconds: seconds,
                                 status: child.process.terminationStatus, stopped: child.stopped, job: lookup,
                                 lastLine: lastLogLine(child)))
    }
    if !finished.isEmpty {
        let gone = Set(finished.map { ObjectIdentifier($0.0) })
        children.removeAll { gone.contains(ObjectIdentifier($0)) }
        runnerStore.pruneLogs(running: Set(children.map { $0.name + ".log" }))
    }
}

/// Runners deleted unused leave now: nothing to look up, and they must not show as running. One GitHub listed idle
/// registered, which is a working start: it clears a failure streak as a deliberate stop does (`RunnerExit.isSuccess`).
private func reapUnused(_ children: inout [RunnerChild], crashes: inout RunnerCrashGuard) {
    guard children.contains(where: \.unused) else { return }
    for c in children where c.unused && c.idle {
        crashes.ended(RunnerExit(kind: c.kind, repo: c.repo, name: c.name, seconds: RunnerClock.now() - c.started,
                                 status: c.process.terminationStatus, stopped: true, job: .none, lastLine: nil))
    }
    children.removeAll(where: \.unused)
    runnerStore.pruneLogs(running: Set(children.map { $0.name + ".log" }))
}

/// A public repo is checked only when it would get a runner; a refusal drops its starts and their evictions.
/// True when `failed` says nothing more should be asked this tick.
// swiftlint:disable:next function_parameter_count
private func checkVisibility(_ plan: inout RunnerTickPlan, demands: [RunnerDemand], polled: [String: RunnerRepo], api: GitHubRunnersAPI,
                             visibility: inout RunnerVisibility, planner: inout RunnerPlanner, note: (String) -> Void,
                             failed: (Error, String) -> Bool) -> Bool {
    for repo in Set(plan.starts.keys.compactMap { k in demands.first { $0.key == k }?.repo }).sorted() {
        guard let r = polled[repo] else { continue }
        do {
            guard let why = try visibility.refusal(r, isPrivate: { r in try blocking { try await api.isPrivate(r) } }) else { continue }
            note(why)
        } catch { if failed(error, repo) { return true } }
        for d in demands where d.repo == repo { plan.starts[d.key] = nil; planner.forget(key: d.key) }
        plan.evictions.removeAll { e in demands.contains { $0.repo == repo && $0.key == e.forKey } }
    }
    return false
}

/// How long a runner of a repo that is not polled may be refused before it is ended here alone.
private let unpolledGiveUp: TimeInterval = 15 * 60

/// A paused, removed or skipped repo is not polled: its runners still end once unused, at most once a minute.
/// True when `failed` says nothing more should be asked this tick.
private func endUnpolled(_ children: [RunnerChild], polled: Set<String>, api: GitHubRunnersAPI, stopping: () -> Bool,
                         failed: (Error, String) -> Bool) -> Bool {
    for child in children where polled.contains(child.repo) { child.refusedSince = nil }
    for child in children where !stopping() && child.live && !polled.contains(child.repo)
        && RunnerClock.now() - child.started > idleTimeout && RunnerClock.now() - child.lastEndTry > 60 {
        child.lastEndTry = RunnerClock.now()
        do {
            if try endUnused(child, api: api) { continue }
            let since = child.refusedSince ?? RunnerClock.now()
            child.refusedSince = since
            // Refused this long (no access, a 403): a repo this Mac cannot reach cannot give it a job either, so end
            // it here; GitHub drops the offline registration on its own. The finished sweep reaps it next tick.
            if RunnerClock.now() - since > unpolledGiveUp { end(child, api: api) }
        } catch { if failed(error, child.repo) { return true } }
    }
    return false
}

/// The helper's last step: end every runner and leave a clean state.
private func shutDown(_ children: [RunnerChild], api: GitHubRunnersAPI, awake: AwakeGuard, state: inout RunnerState) {
    MacRunnerDownload.shared.cancel()
    endAll(children, api: api)
    awake.update(activeJobs: 0)
    state.running = []; state.runningRepos = nil
    state.awake = false
    state.message = nil
    state.hold = nil
    runnerStore.saveState(state)
    try? FileManager.default.removeItem(at: runnerStore.stopMarker)
}

/// One repo's demand per kind this tick. Also learns which of its runners GitHub lists idle and ends those unused too long.
// swiftlint:disable:next function_parameter_count
private func gather(_ repo: RunnerRepo, api: GitHubRunnersAPI, xcode: String?, warm: Set<RunnerKind>, crashes: RunnerCrashGuard,
                    children: [RunnerChild], visibility: RunnerVisibility, note: (String) -> Void,
                    stop: @escaping @Sendable () -> Bool) throws -> [RunnerDemand] {
    let name = repo.repo
    let jobs = try blocking { try await api.queuedJobs(name, stop: stop) }
    var queued: [RunnerKind: Int] = [:]
    for job in jobs {
        if let kind = RunnerLabels.kind(forJobLabels: job.labels, xcodeMajor: xcode), repo.kinds.contains(kind) { queued[kind, default: 0] += 1 }
        // Repeated reasons collapse in note(): one line per repo and reason.
        else if let why = RunnerLabels.refusal(forJobLabels: job.labels, repo: repo.repo, macosAllowed: repo.macos, xcodeMajor: xcode) { note(why) }
    }
    let mine = children.filter { $0.repo == repo.repo && $0.live }
    let wantsWarm = repo.kinds.contains { k in warm.contains(k) && !mine.contains { $0.kind == k } }
    if !queued.isEmpty || !mine.isEmpty || wantsWarm {
        let idle = try blocking { try await api.idleRunnerNames(repo.repo) }
        for child in mine { child.idle = idle.contains(child.name) }
        // A runner nobody gave a job to ends after a while, so it neither lingers nor holds the Mac awake.
        for child in mine where child.idle && RunnerClock.now() - child.started > idleTimeout { _ = try endUnused(child, api: api) }
    }
    var demands: [RunnerDemand] = []
    for kind in RunnerKind.allCases where repo.kinds.contains(kind) {
        let own = mine.filter { $0.kind == kind && $0.live }
        // Cover is only our own live runners: an idle runner of another Mac, or one ended just above, takes nothing.
        let covered = own.filter { $0.idle || RunnerClock.now() - $0.started < RunnerTick.settle }.count
        var d = RunnerDemand(repo: repo.repo, kind: kind, queued: queued[kind] ?? 0, warm: warm.contains(kind) && own.isEmpty,
                             covered: covered, own: own.count)
        // Held back, but still shown to the planner: its two-poll count starts over and its runners stay.
        if d.queued > 0 || d.warm {
            if kind == .linux, !ping() { note("The Noodle engine is not running; Linux jobs wait. Run `noodle start`."); d.blocked = true }
            else if let why = crashes.paused(kind) { note("\(repo.repo): \(why)"); d.blocked = true }
            else if let why = visibility.knownRefusal(repo) { note(why); d.blocked = true }  // the full check runs before a start
        }
        demands.append(d)
    }
    return demands
}

// swiftlint:disable:next function_parameter_count
private func start(_ count: Int, _ kind: RunnerKind, repo: String, api: GitHubRunnersAPI, xcode: String?, crashes: inout RunnerCrashGuard,
                   children: inout [RunnerChild], note: (String) -> Void, stopping: () -> Bool, started: ([RunnerChild]) -> Void) throws {
    for _ in 0..<count where !stopping() {
        // Asked again here: an earlier repo's failed start this tick may have paused this kind.
        if let why = crashes.paused(kind) { note("\(repo): \(why)"); return }
        do { try preflight(kind) } catch is MacRunnerDownload.Pending {
            note("\(repo): downloading the macOS runner; jobs start once it is in place.")
            return
        } catch {
            note("\(repo): cannot start a \(kind.rawValue) runner: \(error.localizedDescription)")
            crashes.failedToStart(kind, repo: repo, reason: error.localizedDescription)
            return
        }
        let name = kind.prefix + String(UUID().uuidString.prefix(8)).lowercased()
        let labels = RunnerLabels.labels(for: kind, xcodeMajor: xcode)
        let jit = try blocking { try await api.jitConfig(repo, name: name, labels: labels) }
        do {
            let child = try spawn(kind, repo: repo, name: name, jit: jit.config)
            child.runnerID = jit.id
            children.append(child)
            // Saved now, not at the end of the tick, so `runners clean` and `cache clear` see the new runner.
            started(children)
        } catch {
            if let id = jit.id { _ = try? blocking { await api.deleteRunner(repo, id: id) } }
            note("\(repo): cannot start a \(kind.rawValue) runner: \(error.localizedDescription)")
            crashes.failedToStart(kind, repo: repo, reason: error.localizedDescription)
            return
        }
    }
}
