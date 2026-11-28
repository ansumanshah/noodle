import Foundation
import Testing
@testable import NoodleCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], String))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (code, headers, body) = Self.handler?(request) ?? (500, [:], "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let secret = "ghp_SECRETTOKEN123"

private func stubbedAPI(_ handler: @escaping (URLRequest) -> (Int, [String: String], String)) -> GitHubRunnersAPI {
    StubProtocol.handler = handler
    StubProtocol.seen = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return GitHubRunnersAPI(session: URLSession(configuration: config)) { secret }
}

private final class FakePower: PowerAssertions, @unchecked Sendable {
    var created = 0, released: [UInt32] = []
    func create() -> UInt32? { created += 1; return UInt32(created) }
    func release(_ id: UInt32) { released.append(id) }
}

@Suite(.serialized) struct RunnersTests {
    @Test func plainNoodleNeverLandsOnTheMac() {
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle"], xcodeMajor: "26") == .linux)
        #expect(RunnerLabels.kind(forJobLabels: ["Self-Hosted", "Noodle", "linux", "arm64"], xcodeMajor: "26") == .linux)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle-macos"], xcodeMajor: "26") == .macos)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle-macos", "xcode-26"], xcodeMajor: "26") == .macos)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle-macos", "xcode-25"], xcodeMajor: "26") == nil)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle", "macos"], xcodeMajor: "26") == nil)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted", "noodle", "noodle-macos"], xcodeMajor: "26") == nil)
        #expect(RunnerLabels.kind(forJobLabels: ["self-hosted"], xcodeMajor: "26") == nil)
        #expect(RunnerLabels.kind(forJobLabels: ["noodle-arc"], xcodeMajor: "26") == nil)
        #expect(!RunnerLabels.linux.contains("noodle-macos"))
        #expect(!RunnerLabels.macos(xcodeMajor: "26").contains("noodle"))
    }

    @Test func xcodeMajorAndCounts() {
        #expect(RunnerLabels.xcodeMajor(fromVersionOutput: "Xcode 26.1\nBuild version 17B55") == "26")
        #expect(RunnerLabels.xcodeMajor(fromVersionOutput: "error") == nil)
        #expect(RunnerLabels.startCount(queued: 3, covered: 1, alive: 0, kind: .linux) == 2)
        #expect(RunnerLabels.startCount(queued: 5, covered: 0, alive: 1, kind: .linux) == 1)
        #expect(RunnerLabels.startCount(queued: 2, covered: 2, alive: 0, kind: .macos) == 0)
        #expect(RunnerLabels.startCount(queued: 2, covered: 0, alive: 1, kind: .macos) == 0)
    }

    @Test func jitRequestKeepsTheTokenInTheHeaderOnly() throws {
        let api = GitHubRunnersAPI { secret }
        let r = api.jitRequest("o/r", name: "noodle-linux-ab12", labels: RunnerLabels.linux)
        #expect(r.url?.path == "/repos/o/r/actions/runners/generate-jitconfig")
        #expect(r.httpMethod == "POST")
        #expect(api.request("/repos/o/r/actions/runs").cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
        #expect(!r.url!.absoluteString.contains(secret))
        let body = try #require(r.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains(secret))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["labels"] as? [String] == RunnerLabels.linux)
        #expect(json["runner_group_id"] as? Int == 1)
        let args = RunnerPin.dockerArguments(name: "noodle-linux-ab12", repo: "o/r")
        #expect(args.contains("/var/run/docker.sock:/var/run/docker.sock") && args.contains("--rm"))
        #expect(!args.joined().contains(secret))
    }

    @Test func queuedJobsAndJitConfigThroughAStubbedSession() async throws {
        let api = stubbedAPI { r in
            let p = r.url!.path
            if p.hasSuffix("/actions/runs") { return (200, [:], #"{"workflow_runs":[{"id":7,"status":"queued"},{"id":8,"status":"completed"}]}"#) }
            if p.hasSuffix("/runs/7/jobs") {
                return (200, [:], #"{"jobs":[{"id":1,"name":"a","status":"queued","labels":["self-hosted","noodle"],"html_url":"u"},{"id":2,"name":"b","status":"in_progress","labels":["x"]}]}"#)
            }
            return (201, [:], #"{"runner":{"id":42},"encoded_jit_config":"CFG"}"#)
        }
        let jobs = try await api.queuedJobs("o/r")
        #expect(jobs.map(\.id) == [1])
        let jit = try await api.jitConfig("o/r", name: "n", labels: ["x"])
        #expect(jit.config == "CFG" && jit.id == 42)
        #expect(StubProtocol.seen.allSatisfy { !$0.url!.absoluteString.contains(secret) })
    }

    @Test func queuedJobsAskOnlyForActiveRunsAndPageThroughJobs() async throws {
        let api = stubbedAPI { r in
            let url = r.url!.absoluteString
            if url.contains("status=queued") { return (200, [:], #"{"workflow_runs":[{"id":7,"status":"queued"}]}"#) }
            if url.contains("status=in_progress") { return (200, [:], #"{"workflow_runs":[{"id":7,"status":"queued"},{"id":9,"status":"in_progress"}]}"#) }
            if url.contains("status=waiting") { return (200, [:], #"{"workflow_runs":[{"id":11,"status":"waiting"}]}"#) }
            let page = Int(URLComponents(string: url)!.queryItems!.first { $0.name == "page" }!.value!)!
            // Run 9 has a full page each time: the loop must stop at its cap. Run 11 has exactly one full page.
            let count = url.contains("/runs/7/") ? 1 : 100, total = url.contains("/runs/11/") ? 100 : 10_000
            let jobs = (0..<count).map { #"{"id":\#(page * 1000 + $0),"status":"queued","labels":["noodle"]}"# }.joined(separator: ",")
            return (200, [:], #"{"total_count":\#(total),"jobs":["# + jobs + "]}")
        }
        let jobs = try await api.queuedJobs("o/r")
        let urls = StubProtocol.seen.map(\.url!.absoluteString)
        #expect(urls.filter { $0.contains("/actions/runs?") }.count == 3)
        #expect(urls.filter { $0.contains("/runs/7/jobs?filter=latest&per_page=100&page=1") }.count == 1)  // run 7 once, though listed twice
        #expect(urls.filter { $0.contains("/runs/9/jobs") }.count == 5)
        #expect(urls.filter { $0.contains("/runs/11/jobs") }.count == 1)  // total_count reached: no empty second page
        #expect(jobs.count == 1 + 500 + 100)
    }

    @Test func anUnchangedListCostsOnlyA304AndAChangedOneReplacesTheCache() async throws {
        nonisolated(unsafe) var tag = "a", runs = #"{"workflow_runs":[{"id":7,"status":"queued"}]}"#
        let api = stubbedAPI { r in
            let url = r.url!.absoluteString
            guard url.contains("status=queued") else {
                if url.contains("/actions/runs?") { return (r.value(forHTTPHeaderField: "If-None-Match") == "e" ? 304 : 200, ["ETag": "e"], #"{"workflow_runs":[]}"#) }
                return (200, [:], #"{"total_count":1,"jobs":[{"id":1,"status":"queued","labels":["noodle"]}]}"#)
            }
            if r.value(forHTTPHeaderField: "If-None-Match") == tag { return (304, ["ETag": tag], "") }
            return (200, ["ETag": tag], runs)
        }
        #expect(try await api.queuedJobs("o/r").map(\.id) == [1])
        #expect(StubProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        StubProtocol.seen = []
        #expect(try await api.queuedJobs("o/r").map(\.id) == [1])  // the 304 reuses the cached run list
        let lists = StubProtocol.seen.filter { $0.url!.absoluteString.contains("/actions/runs?") }
        #expect(lists.count == 3 && lists.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") != nil })
        tag = "b"; runs = #"{"workflow_runs":[]}"#
        #expect(try await api.queuedJobs("o/r").isEmpty)  // a new ETag replaces the list
        StubProtocol.seen = []
        #expect(try await api.queuedJobs("o/r").isEmpty)
        #expect(StubProtocol.seen.first { $0.url!.absoluteString.contains("status=queued") }?.value(forHTTPHeaderField: "If-None-Match") == "b")
    }

    @Test func anIdleTickWithUnchangedListsCostsOnly304s() async throws {
        nonisolated(unsafe) var codes: [Int] = []
        let api = stubbedAPI { r in
            let body = r.url!.path.hasSuffix("/runners") ? #"{"runners":[{"name":"noodle-linux-a","status":"online","busy":false}]}"# : #"{"workflow_runs":[]}"#
            let code = r.value(forHTTPHeaderField: "If-None-Match") == "e" ? 304 : 200
            codes.append(code)
            return (code, ["ETag": "e"], body)
        }
        for _ in 0..<2 { _ = try await api.queuedJobs("o/r"); _ = try await api.idleRunnerNames("o/r") }
        // The runners list is never conditional: its busy flag must be fresh.
        #expect(codes == [200, 200, 200, 200, 304, 304, 304, 200])
        #expect(StubProtocol.seen.filter { $0.url!.path.hasSuffix("/runners") }.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        // Forgetting the sign-in or the repo drops the cached lists: the next ask is a full one.
        api.clearCaches(); codes = []
        _ = try await api.queuedJobs("o/r")
        #expect(codes == [200, 200, 200])
        api.keepCaches(repos: ["o/other"]); codes = []
        _ = try await api.queuedJobs("o/r")
        #expect(codes == [200, 200, 200])
        api.keepCaches(repos: ["o/r"]); codes = []
        _ = try await api.queuedJobs("o/r")
        #expect(codes == [304, 304, 304])
    }

    @Test func aRunsJobsAreReusedUntilItChangesOrAMinutePasses() async throws {
        nonisolated(unsafe) var updated: String? = "T1"
        let api = stubbedAPI { r in
            let url = r.url!.absoluteString
            if url.contains("status=queued") {
                let run = updated.map { #"{"id":7,"status":"queued","updated_at":"\#($0)"}"# } ?? ""
                return (200, [:], #"{"workflow_runs":["# + run + "]}")
            }
            if url.contains("/actions/runs?") { return (200, [:], #"{"workflow_runs":[]}"#) }
            return (200, [:], #"{"total_count":1,"jobs":[{"id":1,"status":"queued","labels":["noodle"]}]}"#)
        }
        func jobAsks(at now: TimeInterval) async throws -> Int {
            StubProtocol.seen = []
            #expect(try await api.queuedJobs("o/r", now: now).map(\.id) == [1])
            return StubProtocol.seen.filter { $0.url!.path.contains("/jobs") }.count
        }
        #expect(try await jobAsks(at: 0) == 1)
        #expect(try await jobAsks(at: 10) == 0)  // same status and updated_at: reused
        updated = "T2"
        #expect(try await jobAsks(at: 20) == 1)  // changed: asked again
        #expect(try await jobAsks(at: 20 + GitHubRunnersAPI.jobsReuse) == 1)  // too old: asked again
        updated = nil
        _ = try await api.queuedJobs("o/r", now: 100)
        #expect(api.etags.runJobs("o/r").isEmpty)  // a run no longer listed is dropped
    }

    /// A `needs` job queues inside an in-progress run without GitHub bumping the run's updated_at.
    @Test func aJobQueuedInsideAnUnchangedRunIsSeenWithinTheShortCap() async throws {
        nonisolated(unsafe) var second = "pending"
        nonisolated(unsafe) var first = "in_progress"
        let api = stubbedAPI { r in
            let url = r.url!.absoluteString
            if url.contains("status=in_progress") {
                return (200, [:], #"{"workflow_runs":[{"id":7,"status":"in_progress","updated_at":"T1"}]}"#)
            }
            if url.contains("/actions/runs?") { return (200, [:], #"{"workflow_runs":[]}"#) }
            return (200, [:], #"{"total_count":2,"jobs":[{"id":1,"status":"\#(first)","labels":["noodle"]},"#
                + #"{"id":2,"status":"\#(second)","labels":["noodle"]}]}"#)
        }
        func queued(at now: TimeInterval) async throws -> [Int] { try await api.queuedJobs("o/r", now: now).map(\.id) }
        #expect(try await queued(at: 0).isEmpty)
        second = "queued"  // build finished, test queued; updated_at unchanged
        #expect(try await queued(at: 10).isEmpty)  // reused: at most the short cap late
        #expect(try await queued(at: GitHubRunnersAPI.jobsReuseUnsettled) == [2])
        // Every job settled: the list is kept for the long cap.
        first = "completed"; second = "completed"
        #expect(try await queued(at: 100).isEmpty)
        second = "queued"
        #expect(try await queued(at: 100 + GitHubRunnersAPI.jobsReuseUnsettled).isEmpty)
        #expect(try await queued(at: 100 + GitHubRunnersAPI.jobsReuse) == [2])
    }

    @Test func deletingARunnerSaysWhetherGitHubAccepted() async throws {
        nonisolated(unsafe) var answer: (Int, [String: String]) = (204, [:])
        let api = stubbedAPI { r in
            #expect(r.httpMethod == "DELETE" && r.url!.path == "/repos/o/r/actions/runners/5")
            return (answer.0, answer.1, "")
        }
        #expect(try await api.removeRunner("o/r", id: 5))
        answer = (422, [:])  // running a job
        #expect(try await !api.removeRunner("o/r", id: 5))
        answer = (404, [:])  // removed in GitHub's settings, or the repo is gone: the local runner may end
        #expect(try await api.removeRunner("o/r", id: 5))
        answer = (403, [:])  // no access: refused
        #expect(try await !api.removeRunner("o/r", id: 5))
        answer = (401, [:])
        await #expect(throws: RunnerAPIError.unauthorized) { _ = try await api.removeRunner("o/r", id: 5) }
        answer = (403, ["x-ratelimit-remaining": "0"])
        await #expect(throws: RunnerAPIError.limited(retryAfter: nil)) { _ = try await api.removeRunner("o/r", id: 5) }
    }

    @Test func jobLookupSkipsRunsOlderThanTheRunner() async throws {
        let api = stubbedAPI { r in
            if r.url!.path.hasSuffix("/actions/runs") {
                return (200, [:], #"{"workflow_runs":[{"id":1,"updated_at":"2026-01-01T10:00:00Z"},{"id":2,"updated_at":"2026-01-01T08:00:00Z"}]}"#)
            }
            return (200, [:], #"{"jobs":[]}"#)
        }
        let started = ISO8601DateFormatter().date(from: "2026-01-01T09:00:00Z")!
        #expect(try await api.job("o/r", ranOn: "noodle-linux-a", since: started) == nil)
        #expect(StubProtocol.seen.map(\.url!.path) == ["/repos/o/r/actions/runs", "/repos/o/r/actions/runs/1/jobs"])
    }

    @Test func limitsAndAuthFailuresSurface() async {
        let limited = stubbedAPI { _ in (429, ["Retry-After": "120"], "") }
        await #expect(throws: RunnerAPIError.limited(retryAfter: 120)) { _ = try await limited.queuedJobs("o/r") }
        let denied = stubbedAPI { _ in (401, [:], "") }
        await #expect(throws: RunnerAPIError.unauthorized) { _ = try await denied.queuedJobs("o/r") }
        #expect(!RunnerAPIError.unauthorized.localizedDescription.contains(secret))
    }

    @Test func backoffGrowsAndAuthStops() {
        var b = RunnerBackoff()
        #expect(b.failure(.limited(retryAfter: nil)) == 60)
        #expect(b.failure(.limited(retryAfter: nil)) == 120)
        #expect(b.failure(.limited(retryAfter: 600)) == 600)
        b.success()
        #expect(b.failure(.limited(retryAfter: nil)) == 60)
        #expect(b.failure(.unauthorized) != nil)
        #expect(b.failure(.unauthorized) != nil)
        #expect(b.failure(.unauthorized) == nil)
    }

    @Test func credentialFillOutputIsParsed() {
        #expect(GitHubToken.parse(fillOutput: "protocol=https\nhost=github.com\nusername=u\npassword=abc\n") == "abc")
        #expect(GitHubToken.parse(fillOutput: "protocol=https\n") == nil)
        #expect(!GitHubToken.fillInput.contains("password"))
    }

    @Test func freshRepoStartsOnTheFirstPoll() {
        var planner = RunnerPlanner()
        #expect(planner.startCount(key: "o/r|linux", queued: 1, covered: 0, alive: 0, kind: .linux) == 0)
        var fresh = RunnerPlanner()
        #expect(fresh.startCount(key: "o/r|linux", queued: 1, covered: 0, alive: 0, kind: .linux, fresh: true) == 1)
    }

    @Test func jobsThisMacNeverTakesSayWhy() {
        #expect(RunnerLabels.refusal(forJobLabels: ["ubuntu-latest"], repo: "o/r", macosAllowed: false, xcodeMajor: nil) == nil)
        #expect(RunnerLabels.refusal(forJobLabels: ["self-hosted", "noodle"], repo: "o/r", macosAllowed: false, xcodeMajor: nil) == nil)
        #expect(RunnerLabels.refusal(forJobLabels: ["noodle-macos"], repo: "o/r", macosAllowed: false, xcodeMajor: "26")
            == "o/r: macOS jobs wait because this repo is not enabled for them. Run `noodle runners add o/r --macos`.")
        #expect(RunnerLabels.refusal(forJobLabels: ["noodle-macos", "xcode-26"], repo: "o/r", macosAllowed: true, xcodeMajor: "26") == nil)
        #expect(RunnerLabels.refusal(forJobLabels: ["noodle-macos", "xcode-25"], repo: "o/r", macosAllowed: true, xcodeMajor: "26")
            == "o/r: jobs asking for xcode-25 wait: this Mac has Xcode 26.")
        #expect(RunnerLabels.refusal(forJobLabels: ["noodle-macos", "xcode-26"], repo: "o/r", macosAllowed: true, xcodeMajor: nil)
            == "o/r: jobs asking for xcode-26 wait: this Mac has no Xcode selected.")
        #expect(RunnerLabels.refusal(forJobLabels: ["noodle", "gpu"], repo: "o/r", macosAllowed: false, xcodeMajor: nil)?
            .hasPrefix("o/r: jobs asking for gpu wait: Noodle's Linux runners have only ") == true)
    }

    @Test func aGapInTheQueueMakesTheNextShortfallWaitAPoll() {
        var planner = RunnerPlanner()
        _ = planner.startCount(key: "k", queued: 1, covered: 0, alive: 0, kind: .linux)
        #expect(planner.startCount(key: "k", queued: 1, covered: 0, alive: 0, kind: .linux) == 1)
        planner.forget(key: "k")
        #expect(planner.startCount(key: "k", queued: 1, covered: 0, alive: 0, kind: .linux) == 0)
    }

    @Test func startScriptLinksToolFoldersIntoTheCache() {
        #expect(RunnerPin.startScript.contains("ln -s /home/runner/.cache/home/$d ~/$d"))
        #expect(RunnerPin.startScript.contains(".bun .cargo"))
    }

    @Test func repoFromRemote() {
        #expect(RunnerStore.repo(fromRemote: "git@github.com:o/r.git\n") == "o/r")
        #expect(RunnerStore.repo(fromRemote: "https://github.com/o/r") == "o/r")
        #expect(RunnerStore.repo(fromRemote: "ssh://git@github.com/o/r.git") == "o/r")
        #expect(RunnerStore.repo(fromRemote: "https://gitlab.com/o/r.git") == nil)
        #expect(RunnerStore.repo(fromRemote: "https://github.com/o/r/extra") == nil)
    }

    @Test func adminReposKeepsOnlyAdminRepos() async throws {
        let api = stubbedAPI { _ in
            (200, [:], #"[{"full_name":"o/a","private":true,"permissions":{"admin":true}},{"full_name":"o/b","private":false,"permissions":{"admin":false}},{"full_name":"o/c","private":false,"permissions":{"admin":true}}]"#)
        }
        let repos = try await api.adminRepos()
        #expect(repos.map(\.repo) == ["o/a", "o/c"])
        #expect(repos.map(\.isPrivate) == [true, false])
        #expect(StubProtocol.seen.first?.url?.path == "/user/repos")
    }

    @Test func visibilityAndJobTimesThroughAStubbedSession() async throws {
        let api = stubbedAPI { r in
            let p = r.url!.path
            if p == "/repos/o/pub" { return (200, [:], #"{"private":false}"#) }
            if p == "/repos/o/priv" { return (200, [:], #"{"private":true}"#) }
            if p.hasSuffix("/actions/runs") { return (200, [:], #"{"workflow_runs":[{"id":7}]}"#) }
            return (200, [:], #"{"jobs":[{"id":1,"name":"j","status":"completed","runner_name":"noodle-linux-a","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:30Z"}]}"#)
        }
        let priv = try await api.isPrivate("o/priv"), pub = try await api.isPrivate("o/pub")
        #expect(priv && !pub)
        #expect(try await api.job("o/r", ranOn: "noodle-linux-a")?.seconds == 90)
    }

    @Test func repoNames() {
        #expect(RunnerStore.validRepo("acme/app"))
        #expect(!RunnerStore.validRepo("a/b/c") && !RunnerStore.validRepo("../x") && !RunnerStore.validRepo("a/") && !RunnerStore.validRepo("a b/c"))
    }

    @Test func workflowCheckFindings() {
        let yaml = """
        name: ci
        on: push
        jobs:
          app:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - run: xcodebuild -scheme App test
          lint:
            runs-on: macos-14
            steps:
              - run: npm test
          win:
            runs-on: windows-latest
            steps:
              - run: dir
          intel:
            runs-on: ubuntu-24.04
            steps:
              - run: docker run --platform linux/amd64 alpine true
          here:
            runs-on: [self-hosted, noodle]
            steps:
              - run: echo hi
          plain:
            runs-on: ubuntu-24.04
            steps:
              - run: make
          arc:
            runs-on: noodle-arc
            steps:
              - run: make
        """
        let found = Dictionary(uniqueKeysWithValues: WorkflowCheck.check(yaml: yaml, file: "ci.yml").map { ($0.job, $0) })
        #expect(found["app"]?.kind == .needsMacOS && found["app"]?.suggestion == "[self-hosted, noodle-macos]")
        #expect(found["lint"]?.kind == .macOSForNothing && found["lint"]?.suggestion == "[self-hosted, noodle]")
        #expect(found["win"]?.kind == .cannotRunHere && found["win"]?.suggestion == nil)
        #expect(found["intel"]?.kind == .cannotRunHere)
        #expect(found["here"]?.kind == .ready)
        #expect(found["plain"]?.kind == .hosted)
        #expect(found["arc"]?.kind == .other)
    }

    @Test func awakeGuardHoldsOneAssertionOnlyWhileJobsRun() {
        let power = FakePower()
        let guardian = AwakeGuard(api: power)
        guardian.update(activeJobs: 0)
        #expect(power.created == 0 && !guardian.holding)
        guardian.update(activeJobs: 1); guardian.update(activeJobs: 2); guardian.update(activeJobs: 1)
        #expect(power.created == 1 && guardian.holding && power.released.isEmpty)
        guardian.update(activeJobs: 0); guardian.update(activeJobs: 0)
        #expect(power.released == [1] && !guardian.holding)
        guardian.update(activeJobs: 1)
        #expect(power.created == 2)
    }

    @Test func dockerArgumentsCarryNoJitConfig() {
        let jit = "eyJTRUNSRVQ"
        let args = RunnerPin.dockerArguments(name: "noodle-linux-ab12", repo: "o/r")
        #expect(args.starts(with: ["run", "-i", "--rm", "--name", "noodle-linux-ab12"]))
        #expect(!args.contains("-e") && !args.joined(separator: " ").contains(jit))
        #expect(args.last == RunnerPin.startScript && RunnerPin.startScript.hasSuffix("exec ./run.sh"))
        #expect(args.contains("noodle-runner-cache-o_r:/home/runner/.cache"))
    }

    @Test func forbiddenIsARateLimitOnlyWithTheHeaders() async {
        let plain = stubbedAPI { _ in (403, [:], "") }
        await #expect(throws: RunnerAPIError.forbidden) { _ = try await plain.queuedJobs("o/r") }
        let empty = stubbedAPI { _ in (403, ["x-ratelimit-remaining": "0"], "") }
        await #expect(throws: RunnerAPIError.limited(retryAfter: nil)) { _ = try await empty.queuedJobs("o/r") }
        let after = stubbedAPI { _ in (403, ["Retry-After": "30"], "") }
        await #expect(throws: RunnerAPIError.limited(retryAfter: 30)) { _ = try await after.queuedJobs("o/r") }
        var b = RunnerBackoff()
        #expect(b.failure(.forbidden) == nil)
    }

    @Test func workflowPathsArePercentEncoded() async throws {
        let api = stubbedAPI { _ in (200, [:], "x") }
        _ = try await api.file("o/r", path: ".github/workflows/my flow#1.yml")
        #expect(StubProtocol.seen.last?.url?.absoluteString.hasSuffix("/contents/.github/workflows/my%20flow%231.yml") == true)
    }

    @Test func aRunnerThatJustWentBusyDoesNotStartAnExtraOne() async throws {
        // Poll 1: one job queued, nothing covers it. Poll 2: our runner took it (busy, so not idle, past the starting
        // window) but GitHub still lists the job as queued. The shortfall shows on poll 2 only if it showed on poll 1.
        var planner = RunnerPlanner()
        let api = stubbedAPI { r in
            let p = r.url!.path
            if p.hasSuffix("/actions/runs") { return (200, [:], #"{"workflow_runs":[{"id":7,"status":"queued"}]}"#) }
            if p.hasSuffix("/jobs") {
                return (200, [:], #"{"jobs":[{"id":1,"name":"j","status":"queued","labels":["self-hosted","noodle"],"html_url":"u"}]}"#)
            }
            return (200, [:], #"{"runners":[{"name":"noodle-linux-aa","status":"online","busy":true}]}"#)
        }
        func poll() async throws -> Int {
            let queued = try await api.queuedJobs("o/r").count
            let idle = try await api.idleRunnerNames("o/r")
            return planner.startCount(key: "o/r|linux", queued: queued, covered: idle.count, alive: 1, kind: .linux)
        }
        #expect(try await poll() == 0)  // first sight of the shortfall waits one poll
        // The job leaves the queue before the next poll: nothing starts, and the memory resets.
        #expect(planner.startCount(key: "o/r|linux", queued: 0, covered: 0, alive: 1, kind: .linux) == 0)
        #expect(try await poll() == 0)
        #expect(try await poll() == 1)  // still queued and uncovered on two polls in a row: a real shortfall
    }
}
