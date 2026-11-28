import Foundation

public struct RunnerJob: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var labels: [String]
    public var runnerName: String?
    public var url: String
    /// Run time from GitHub's started_at to completed_at, when both are set.
    public var seconds: Int?
}

public enum RunnerAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case limited(retryAfter: TimeInterval?)
    case forbidden
    case http(Int)
    case network

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub did not accept the saved sign-in."
        case .limited: "GitHub is limiting requests."
        case .forbidden: "GitHub refused the request: the saved sign-in needs the repo scope and admin access to this repository."
        case .http(let code): "GitHub answered \(code)."
        case .network: "Could not reach GitHub."
        }
    }
}

/// Sleep time after 403/429 grows 60 s, 120 s, ... up to 15 min; three 401s in a row end the helper.
public struct RunnerBackoff: Sendable {
    public private(set) var limited = 0
    public private(set) var authFailures = 0
    public init() {}

    public mutating func success() { limited = 0; authFailures = 0 }

    /// Seconds to wait before the next request, or nil to give up (auth failed repeatedly).
    public mutating func failure(_ error: RunnerAPIError) -> TimeInterval? {
        switch error {
        case .unauthorized:
            authFailures += 1
            return authFailures >= 3 ? nil : 10
        case .forbidden:
            return nil
        case .limited(let after):
            limited += 1
            return max(after ?? 0, min(900, 60 * pow(2, Double(limited - 1))))
        default:
            return 10
        }
    }
}

/// The last run lists with their ETags (GitHub does not count a 304 against the rate limit) and each active run's jobs.
final class GitHubCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (etag: String, data: Data)] = [:]
    private var runs: [String: [Int: (stamp: String, at: TimeInterval, jobs: [RunnerJob])]] = [:]
    subscript(url: String) -> (etag: String, data: Data)? {
        get { lock.withLock { entries[url] } }
        set { lock.withLock { entries[url] = newValue } }
    }
    func runJobs(_ repo: String) -> [Int: (stamp: String, at: TimeInterval, jobs: [RunnerJob])] { lock.withLock { runs[repo] ?? [:] } }
    func setRunJobs(_ repo: String, _ value: [Int: (stamp: String, at: TimeInterval, jobs: [RunnerJob])]) { lock.withLock { runs[repo] = value } }
    func keep(repos: Set<String>) {
        lock.withLock {
            entries = entries.filter { e in repos.contains { e.key.contains("/repos/\($0)/") } }
            runs = runs.filter { repos.contains($0.key) }
        }
    }
    func clear() { lock.withLock { entries = [:]; runs = [:] } }
}

/// GitHub's own REST API for self-hosted runners. The token comes from `token()` per request and is only ever put
/// in the Authorization header: not in URLs, bodies, arguments or errors.
public struct GitHubRunnersAPI: Sendable {
    let session: URLSession
    let token: @Sendable () -> String?
    let base: String
    let etags = GitHubCache()

    public init(session: URLSession = .shared, base: String = "https://api.github.com", token: @escaping @Sendable () -> String?) {
        self.session = session; self.base = base; self.token = token
    }

    public func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        // GitHub answers with max-age=60; a cached job list would start runners up to a minute late.
        var r = URLRequest(url: URL(string: base + path) ?? URL(fileURLWithPath: "/"),
                           cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Noodle", forHTTPHeaderField: "User-Agent")
        if let t = token() { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    /// 401 is a bad sign-in. A 403 is a rate limit only with Retry-After or an empty quota; otherwise the token lacks permission.
    static func failure(_ http: HTTPURLResponse?) -> RunnerAPIError {
        let code = http?.statusCode ?? 0
        switch code {
        case 401: return .unauthorized
        case 403, 429:
            var wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let empty = http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            if wait == nil, empty, let reset = http?.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
                wait = max(0, reset - Date().timeIntervalSince1970)
            }
            return wait != nil || empty || code == 429 ? .limited(retryAfter: wait) : .forbidden
        default: return .http(code)
        }
    }

    /// `conditional`: sends the last ETag for this URL, and a 304 reuses the last answer.
    func json(_ request: URLRequest, conditional: Bool = false) async throws -> [String: Any] {
        var request = request
        let key = request.url?.absoluteString ?? ""
        let cached = conditional ? etags[key] : nil
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        var data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw RunnerAPIError.network }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 304, let cached { data = cached.data }
        else if !(200..<300).contains(code) { throw Self.failure(http) }
        else if conditional, let etag = http?.value(forHTTPHeaderField: "ETag") { etags[key] = (etag, data) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func job(_ o: [String: Any]) -> RunnerJob? {
        guard let id = o["id"] as? Int, let status = o["status"] as? String else { return nil }
        return RunnerJob(id: id, name: o["name"] as? String ?? "", status: status, conclusion: o["conclusion"] as? String,
                         labels: o["labels"] as? [String] ?? [], runnerName: o["runner_name"] as? String,
                         url: o["html_url"] as? String ?? "", seconds: seconds(o["started_at"], o["completed_at"]))
    }

    static func seconds(_ start: Any?, _ end: Any?) -> Int? {
        let f = ISO8601DateFormatter()
        guard let a = (start as? String).flatMap(f.date(from:)), let b = (end as? String).flatMap(f.date(from:)) else { return nil }
        return max(0, Int(b.timeIntervalSince(a)))
    }

    /// Runs that may hold a queued job: queued runs, running ones (a matrix waits for runners inside an in-progress
    /// run) and waiting ones (an approved deployment's jobs queue inside a waiting run). Newest first, without repeats,
    /// at most `maxRuns`. The lists are conditional, so an unchanged one costs no rate limit.
    static let maxRuns = 20, maxJobPages = 5

    /// Drops what is cached for repos not in `repos`.
    public func keepCaches(repos: Set<String>) { etags.keep(repos: repos) }
    /// Drops everything cached: the sign-in was forgotten or changed.
    public func clearCaches() { etags.clear() }

    /// A run's jobs are reused while its status and updated_at are unchanged: for `jobsReuse` when every job was
    /// completed or waiting on an approval, else for `jobsReuseUnsettled`, since a job can queue inside an in-progress
    /// run (a `needs` finished) without GitHub bumping updated_at. It errs late, never early: a new queued job is seen
    /// at most `jobsReuseUnsettled` late, and a taken one shows as queued no longer than a new runner counts as
    /// covering it (`RunnerTick.settle`), so it never causes an extra start.
    static let jobsReuse: TimeInterval = 60, jobsReuseUnsettled: TimeInterval = 20

    /// Active runs with a stamp of their status and updated_at, nil when GitHub sent no updated_at.
    func activeRuns(_ repo: String) async throws -> [(id: Int, stamp: String?)] {
        var ids: [(id: Int, stamp: String?)] = []
        for status in ["queued", "in_progress", "waiting"] {
            let runs = try await json(request("/repos/\(repo)/actions/runs?status=\(status)&per_page=\(Self.maxRuns)"), conditional: true)["workflow_runs"] as? [[String: Any]] ?? []
            for run in runs where run["status"] as? String == status {
                if let id = run["id"] as? Int, !ids.contains(where: { $0.id == id }) { ids.append((id, (run["updated_at"] as? String).map { status + " " + $0 })) }
            }
        }
        return Array(ids.prefix(Self.maxRuns))
    }

    /// Every job of a run's latest attempt, a page of 100 at a time, at most `maxJobPages` pages.
    func jobs(_ repo: String, run: Int) async throws -> [RunnerJob] {
        var all: [RunnerJob] = []
        for page in 1...Self.maxJobPages {
            let o = try await json(request("/repos/\(repo)/actions/runs/\(run)/jobs?filter=latest&per_page=100&page=\(page)"))
            let list = o["jobs"] as? [[String: Any]] ?? []
            all += list.compactMap(Self.job)
            if list.count < 100 || all.count >= o["total_count"] as? Int ?? Int.max { break }
        }
        return all
    }

    /// Queued jobs of the active runs. `stop` is asked before each run, so a stopping helper does not page on.
    public func queuedJobs(_ repo: String, now: TimeInterval = RunnerClock.now(), stop: () -> Bool = { false }) async throws -> [RunnerJob] {
        let known = etags.runJobs(repo)
        var queued: [RunnerJob] = [], seen: [Int: (stamp: String, at: TimeInterval, jobs: [RunnerJob])] = [:]
        for run in try await activeRuns(repo) {
            if stop() { break }
            let list: [RunnerJob]
            if let stamp = run.stamp, let hit = known[run.id], hit.stamp == stamp,
               now - hit.at < (hit.jobs.allSatisfy { ["completed", "waiting"].contains($0.status) } ? Self.jobsReuse : Self.jobsReuseUnsettled) {
                list = hit.jobs; seen[run.id] = hit
            } else {
                list = try await jobs(repo, run: run.id)
                if let stamp = run.stamp { seen[run.id] = (stamp, now, list) }
            }
            queued += list.filter { $0.status == "queued" }
        }
        etags.setRunJobs(repo, seen)  // runs no longer listed are dropped
        return queued
    }

    /// Names of our runners that are online and not running a job.
    public func idleRunnerNames(_ repo: String) async throws -> Set<String> {
        // Never conditional: a stale busy flag could end a runner that just took a job.
        let list = try await json(request("/repos/\(repo)/actions/runners?per_page=100"))["runners"] as? [[String: Any]] ?? []
        return Set(list.filter { $0["status"] as? String == "online" && $0["busy"] as? Bool == false }
            .compactMap { $0["name"] as? String }.filter { $0.hasPrefix("noodle-") })
    }

    /// The job a finished runner took, found among the newest runs. Nil means GitHub answered and there was none; an error means unknown.
    /// Only runs updated since the runner started can hold its job, so older runs cost no request.
    public func job(_ repo: String, ranOn runner: String, since started: Date = .distantPast) async throws -> RunnerJob? {
        let runs = try await json(request("/repos/\(repo)/actions/runs?per_page=30"))["workflow_runs"] as? [[String: Any]] ?? []
        let f = ISO8601DateFormatter(), from = started.addingTimeInterval(-300)  // GitHub's clock and ours may differ
        let recent = runs.filter { (($0["updated_at"] as? String).flatMap(f.date(from:)) ?? .distantFuture) >= from }
        for id in recent.compactMap({ $0["id"] as? Int }) {
            if let hit = try await jobs(repo, run: id).first(where: { $0.runnerName == runner }) { return hit }
        }
        return nil
    }

    public func jitRequest(_ repo: String, name: String, labels: [String]) -> URLRequest {
        let body: [String: Any] = ["name": name, "runner_group_id": 1, "labels": labels, "work_folder": "_work"]
        return request("/repos/\(repo)/actions/runners/generate-jitconfig", method: "POST",
                       body: try? JSONSerialization.data(withJSONObject: body))
    }

    /// The encoded JIT config: a single-use runner credential, handed to the runner on stdin (Linux) or through its environment (macOS).
    /// Also returns the runner's id, so a runner that never takes a job can be unregistered.
    public func jitConfig(_ repo: String, name: String, labels: [String]) async throws -> (config: String, id: Int?) {
        let reply = try await json(jitRequest(repo, name: name, labels: labels))
        guard let config = reply["encoded_jit_config"] as? String else { throw RunnerAPIError.http(0) }
        return (config, (reply["runner"] as? [String: Any])?["id"] as? Int)
    }

    /// Deletes a runner. True when it is gone on GitHub: deleted now, or already (404: removed in GitHub's settings,
    /// or the repo deleted or renamed), so the local runner can end. False when GitHub refused, as it does (422) for a
    /// runner running a job, or without access (403): leave it alone. A bad sign-in or a rate limit throws, so the
    /// caller backs off.
    public func removeRunner(_ repo: String, id: Int) async throws -> Bool {
        let response: URLResponse
        do { (_, response) = try await session.data(for: request("/repos/\(repo)/actions/runners/\(id)", method: "DELETE")) }
        catch { throw RunnerAPIError.network }
        let http = response as? HTTPURLResponse
        if (200..<300).contains(http?.statusCode ?? 0) || http?.statusCode == 404 { return true }
        switch Self.failure(http) {
        case .unauthorized: throw RunnerAPIError.unauthorized
        case .limited(let wait): throw RunnerAPIError.limited(retryAfter: wait)
        default: return false
        }
    }

    /// Unregisters a runner. Best effort: a single-use runner that ran a job is already gone (404).
    public func deleteRunner(_ repo: String, id: Int) async {
        _ = try? await session.data(for: request("/repos/\(repo)/actions/runners/\(id)", method: "DELETE"))
    }

    static func encoded(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "" }

    /// Whether the repo is private. Throws when it cannot be read.
    public func isPrivate(_ repo: String) async throws -> Bool {
        guard let flag = try await json(request("/repos/\(repo)"))["private"] as? Bool else { throw RunnerAPIError.http(0) }
        return flag
    }

    /// Contents of one file in the repo through the contents API (raw media type). Nil when it does not exist.
    public func file(_ repo: String, path: String) async throws -> String? {
        var r = request("/repos/\(repo)/contents/\(Self.encoded(path))")
        r.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return nil }
            guard code == 200 else { throw Self.failure(response as? HTTPURLResponse) }
            return String(decoding: data, as: UTF8.self)
        } catch let e as RunnerAPIError { throw e } catch { throw RunnerAPIError.network }
    }

    /// Repos the signed-in user administers (runner registration needs admin), most recently pushed first.
    /// shortcut: first 100 only; add paging when someone administers more.
    public func adminRepos() async throws -> [(repo: String, isPrivate: Bool)] {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request("/user/repos?per_page=100&sort=pushed")) } catch { throw RunnerAPIError.network }
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw Self.failure(http) }
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.filter { ($0["permissions"] as? [String: Any])?["admin"] as? Bool == true }
            .compactMap { o in (o["full_name"] as? String).map { ($0, o["private"] as? Bool ?? false) } }
    }

    /// File names under a directory, or [] when there is none.
    public func listing(_ repo: String, path: String) async throws -> [String] {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request("/repos/\(repo)/contents/\(Self.encoded(path))")) } catch { throw RunnerAPIError.network }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return [] }
        guard code == 200 else { throw Self.failure(response as? HTTPURLResponse) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }
}

/// The user's GitHub token from git's own credential helper, the one Settings can save into.
public enum GitHubToken {
    public static let fillInput = "protocol=https\nhost=github.com\n\n"

    public static func parse(fillOutput: String) -> String? {
        for line in fillOutput.split(separator: "\n") where line.hasPrefix("password=") {
            let t = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// Runs `git credential fill`, killed after `timeout` seconds (a credential helper can hang on a prompt or the
    /// network). The token only travels over the pipe: never in arguments, never printed.
    public static func fill(timeout: TimeInterval = 15) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["credential", "fill"]
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let wrote = (try? input.fileHandleForWriting.write(contentsOf: Data(fillInput.utf8))) != nil
        try? input.fileHandleForWriting.close()
        // Always reaped. The answer is a few lines, well inside the pipe buffer, so waiting first cannot block git; and
        // a killed git is never read, since a helper it started may still hold the pipe open.
        p.waitUntilExit()
        deadline.cancel()
        guard wrote, p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return parse(fillOutput: String(decoding: output.fileHandleForReading.availableData, as: UTF8.self))
    }
}

/// GitHub's official macOS runner, pinned like ToolPins. Kept out of ToolPins.swift because it is not a Docker tool.
public enum RunnerPin {
    public static let version = "2.338.2"
    public static let sha256 = "25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388"
    public static var file: String { "actions-runner-osx-arm64-\(version).tar.gz" }
    public static var url: String { "https://github.com/actions/runner/releases/download/v\(version)/\(file)" }
    /// The matching Linux arm64 image from GitHub's registry.
    public static var image: String { "ghcr.io/actions/actions-runner:\(version)" }

    /// Where the per-repo cache volume sits in the container: `~/.cache` (npm, pip, Go, Gradle wrappers) and the tool cache.
    public static let cachePath = "/home/runner/.cache"
    /// Toolchain folders in the home folder that installers such as setup-bun, rustup and pip --user fill; each is
    /// linked into the cache volume so it stays installed between jobs.
    public static let cachedHomeFolders = [".bun", ".cargo", ".rustup", ".npm", ".gradle", ".m2", ".nuget", ".deno", ".local"]
    public static let startScript = "sudo chown runner \(cachePath) 2>/dev/null; export RUNNER_TOOL_CACHE=\(cachePath)/tools; "
        + "for d in \(cachedHomeFolders.joined(separator: " ")); do mkdir -p \(cachePath)/home/$d; [ -e ~/$d ] || ln -s \(cachePath)/home/$d ~/$d; done; "
        + "read -r ACTIONS_RUNNER_INPUT_JITCONFIG; export ACTIONS_RUNNER_INPUT_JITCONFIG; exec ./run.sh"

    /// One cache volume per repo, so a job starts with the last job's downloads and no other repo can touch them.
    public static func cacheVolume(repo: String) -> String { "noodle-runner-cache-" + repo.replacingOccurrences(of: "/", with: "_") }

    /// The JIT config is read from stdin, so it never appears in these arguments, `ps` or `docker inspect`.
    /// shortcut: two jobs of one repo share the cache volume at once; tools that lock their cache (npm, pip, Go) cope.
    public static func dockerArguments(name: String, repo: String) -> [String] {
        ["run", "-i", "--rm", "--name", name, "-v", "/var/run/docker.sock:/var/run/docker.sock",
         "-v", cacheVolume(repo: repo) + ":" + cachePath, image, "sh", "-c", startScript]
    }
}
