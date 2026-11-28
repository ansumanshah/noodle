import Darwin
import Foundation
import Testing
@testable import NoodleCore

@Suite struct LocalModelLaunchTests {
    @Test(arguments: ["run", "serve"], [false, true])
    func policyChangePreservesActiveRunnerAndKey(command: String, legacy: Bool) throws {
        let fixture = try RunnerFixture(needsListener: false)
        defer { fixture.cleanUp() }
        let active = Process()
        active.executableURL = URL(fileURLWithPath: "/bin/sleep")
        active.arguments = ["60"]
        try active.run()
        defer {
            if active.isRunning { active.terminate() }
            active.waitUntilExit()
        }
        try fixture.recordActiveSession(pid: active.processIdentifier, keepAlive: legacy ? nil : .default)
        let sessionFile = fixture.home.appendingPathComponent("models/session.json")
        let keyFile = fixture.home.appendingPathComponent("models/key")
        let session = try Data(contentsOf: sessionFile)
        let key = try Data(contentsOf: keyFile)
        let result = fixture.command([command, "fixture", "--keep-alive", "1h"])
        #expect(result.code != 0 && result.output.contains("noodle model stop"))
        #expect(active.isRunning)
        #expect(try Data(contentsOf: sessionFile) == session)
        #expect(try Data(contentsOf: keyFile) == key)
    }

    @Test(arguments: ["/tmp/model-scratch/arm64-apple-macosx/release/NoodleEngineTests.xctest",
                      "/tmp/model-scratch/arm64-apple-macosx/debug/NoodleEngineTests.xctest"])
    func executableFollowsActiveProducts(_ path: String) {
        let bundle = URL(fileURLWithPath: path)
        let expected = bundle.deletingLastPathComponent().appendingPathComponent("noodle")
        #expect(RunnerFixture.executableURL(testBundle: bundle, override: nil) == expected)
        #expect(RunnerFixture.executableURL(testBundle: bundle, override: "/tmp/explicit-noodle").path == "/tmp/explicit-noodle")
    }

    @Test(arguments: zip(["5m", "0", "-1", "250ms", "1.001s"], ["300", "1", "off", "1", "2"]))
    func execsSharedEngineWithIdleEviction(text: String, expected: String) throws {
        let fixture = try RunnerFixture(needsListener: false)
        defer { fixture.cleanUp() }
        let (arguments, pid, recordedPID) = try fixture.captureLaunch(keepAlive: .init(text))
        if expected == "off" {
            #expect(!arguments.contains("--idle-evict-secs"))
        } else {
            let index = try #require(arguments.firstIndex(of: "--idle-evict-secs"))
            #expect(arguments[index + 1] == expected)
        }
        #expect(arguments[try #require(arguments.firstIndex(of: "--port")) + 1] == String(fixture.port))
        #expect(arguments.contains("--model-dir") && arguments.contains("--api-key-strict"))
        #expect(!arguments.contains("--model"))
        #expect(pid == recordedPID, "The runtime must be a child of the launch process, which supervises it")
    }
}

/// Loopback HTTP fixtures, synthetic GGUF headers, and the built CLI. No weights or network downloads.
@Suite(.tags(.slow), .enabled(if: RunnerFixture.canBindLoopback, "Requires permission to bind a loopback listener"))
struct LocalModelRunnerTests {
    @Test func stopDoesNotReselectAModelReloadedByAConcurrentRequest() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m")
        try Data().write(to: fixture.home.appendingPathComponent("reload-on-unload"))
        #expect(fixture.command(["stop"]).code == 0)
        #expect(try fixture.status().phase == .stopped)
    }

    @Test func crashedRuntimeIsRestartedAndCounted() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m", environment: ["NOODLE_MODEL_RESTART_BASE_DELAY": "0.05"])
        try Data().write(to: fixture.home.appendingPathComponent("crash-now"))
        let restarted = fixture.eventually { (try? fixture.status())?.restarts == 1 && fixture.startedPIDs().count == 2 }
        #expect(restarted)
        #expect(try fixture.status().lastCrash != nil)
    }

    @Test func stopKillsARuntimeWhoseSupervisorWasKilled() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m")
        let runtime = try #require(fixture.startedPIDs().last)
        kill(try fixture.supervisorPID(), SIGKILL)
        #expect(fixture.eventually { (try? fixture.status().phase) == .stopped })
        #expect(kill(runtime, 0) == 0, "the orphan keeps running until Stop")
        #expect(fixture.command(["stop"]).code == 0)
        #expect(fixture.eventually { kill(runtime, 0) != 0 })
    }

    @Test func terminateDuringBackoffExitsPromptly() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m", environment: ["NOODLE_MODEL_RESTART_BASE_DELAY": "30"])
        let supervisor = try fixture.supervisorPID()
        try Data().write(to: fixture.home.appendingPathComponent("crash-now"))
        #expect(fixture.eventually { (try? fixture.status())?.restarts == 1 })
        kill(supervisor, SIGTERM)
        #expect(fixture.eventually(seconds: 3) { kill(supervisor, 0) != 0 })
    }

    @Test func ggufAndMLXShareAProcessAndKeyUntilTheLastModelStops() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m")
        let endpoint = try fixture.endpoint()
        let sessionFile = fixture.home.appendingPathComponent("models/session.json")
        let before = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile)) as? [String: Any])
        // Import after startup so serving it also proves the running registry was rescanned.
        try fixture.install("second", mlx: true)
        let served = fixture.command(["serve", "second", "--port", String(fixture.port)])
        try #require(served.code == 0, Comment(rawValue: served.output))
        #expect(try fixture.status().model == "second")
        #expect(try fixture.endpoint().apiKey == endpoint.apiKey)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile)) as? [String: Any])
        #expect(after["id"] as? String == before["id"] as? String)
        #expect((after["process"] as? [String: Int]) == (before["process"] as? [String: Int]))
        #expect(fixture.command(["run", "fixture", "hello"]).output.contains("fixture reply: fixture"))
        #expect(fixture.command(["run", "second", "hello"]).output.contains("fixture reply: second"))
        #expect(fixture.command(["rm", "fixture"]).code != 0, "A resident nonselected model keeps its weights.")
        #expect(fixture.command(["stop"]).code == 0)
        #expect(try fixture.status().model == "fixture")
        #expect(try fixture.endpoint().apiKey == endpoint.apiKey)
        #expect(fixture.command(["stop"]).code == 0)
        #expect(try fixture.status().phase == .stopped)
    }

    @Test func failedPreloadKeepsTheExistingModelProcessAndCredentials() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m")
        try fixture.install("fail")
        let endpoint = try fixture.endpoint()
        let sessionFile = fixture.home.appendingPathComponent("models/session.json")
        let before = try Data(contentsOf: sessionFile)
        let result = fixture.command(["serve", "fail", "--port", String(fixture.port)])
        #expect(result.code != 0)
        #expect(try Data(contentsOf: sessionFile) == before)
        #expect(try fixture.status().model == "fixture")
        #expect(try fixture.endpoint().apiKey == endpoint.apiKey)
    }

    @Test func policyChangePreservesAnActiveResponseAndCredentials() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "5m")
        let endpoint = try fixture.endpoint()
        let sessionFile = fixture.home.appendingPathComponent("models/session.json")
        let originalSession = try Data(contentsOf: sessionFile)
        let request = try fixture.request(endpoint: endpoint, path: "v1/chat/completions",
            body: ["model": "fixture", "messages": [], "stream": true])
        let response = Task { try await URLSession.shared.data(for: request) }
        defer { response.cancel() }
        let release = fixture.home.appendingPathComponent("release-response")
        defer { try? Data().write(to: release) }
        try await waitUntil(timeout: .seconds(5)) { FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("request-active").path) }
        try #require(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("request-active").path))
        for command in ["run", "serve"] {
            let result = fixture.command([command, "fixture", "--keep-alive", "1h"] +
                (command == "serve" ? ["--port", String(fixture.port)] : []))
            #expect(result.code != 0 && result.output.contains("noodle model stop"))
        }
        #expect(try Data(contentsOf: sessionFile) == originalSession)
        #expect(try fixture.endpoint().apiKey == endpoint.apiKey)
        try Data().write(to: release)
        let (data, result) = try await response.value
        #expect((result as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("[DONE]"))
        #expect(try fixture.endpoint().apiKey == endpoint.apiKey)
    }

    @Test func negativeDurationKeepsServingAndStopStillWorks() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        try fixture.serve(keepAlive: "-1")
        #expect(try fixture.status().phase == .ready)
        #expect(fixture.command(["stop"]).code == 0)
        #expect(try fixture.status().phase == .stopped)
    }

    @Test func commandLineOverridesEnvironmentAndRejectsBadOptionsBeforePull() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        for arguments in [["run", "missing", "--keep-alive", "bad"],
                          ["serve", "missing", "--keep-alive"],
                          ["run", "missing", "--keep-alive", "5m", "--keep-alive", "0"]] {
            let result = fixture.command(arguments)
            #expect(result.code != 0 && result.output.contains("keep-alive"))
        }
        let served = fixture.command(["serve", "fixture", "--port", String(fixture.port), "--keep-alive=-1"],
                                     environment: ["NOODLE_MODEL_KEEP_ALIVE": "invalid"])
        #expect(served.code == 0)
        #expect(try fixture.status().phase == .ready)
    }

    @Test func huggingFaceReceiptSupportsPullRunListAndRemoveOffline() throws {
        let fixture = try RunnerFixture()
        defer { fixture.cleanUp() }
        let reference = try LocalModelHuggingFace.Reference("hf.co/Fixture/Repo:q4_k_m")
        let bundle = fixture.home.appendingPathComponent("models/weights/huggingface/\(reference.storageKey)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let data = Data("GGUF".utf8) + Data(repeating: 0, count: 24)
        let target = bundle.appendingPathComponent("model.gguf")
        try data.write(to: target)
        let receipt = try LocalModelHuggingFace.Receipt(logicalID: reference.id, revision: String(repeating: "a", count: 40),
            filename: "fixture.Q4_K_M.gguf", sha256: Digest.sha256(data), bytes: UInt64(data.count))
        try JSONEncoder().encode(receipt).write(to: bundle.appendingPathComponent("receipt.json"))
        let pull = fixture.command(["pull", "hf.co/Fixture/Repo:q4_k_m", "--progress-json"])
        #expect(pull.code == 0)
        let progress = try pull.output.split(separator: "\n").map {
            try JSONDecoder().decode(LocalModelPullProgress.self, from: Data($0.utf8))
        }
        #expect(progress.map(\.phase) == [.verifying, .installed])
        let listing = fixture.command(["list", "--json"])
        let models = try JSONDecoder().decode([LocalModel].self, from: Data(listing.output.utf8))
        #expect(models.contains { $0.id == reference.id && $0.installed && $0.backend == .llamaCPP })
        let serve = fixture.command(["serve", "hf.co/Fixture/Repo:q4_k_m", "--port", String(fixture.port), "--keep-alive", "-1"])
        try #require(serve.code == 0, Comment(rawValue: serve.output))
        #expect(fixture.command(["run", reference.id, "hello"]).output.contains("fixture reply"))
        #expect(fixture.command(["rm", reference.id]).code != 0)
        #expect(fixture.command(["stop"]).code == 0)
        var corrupted = data
        corrupted[corrupted.count - 1] = 1
        try corrupted.write(to: target)
        let rejected = fixture.command(["pull", reference.id, "--progress-json"])
        #expect(rejected.code != 0 && rejected.output.contains("differ from their receipt"))
        #expect(fixture.command(["rm", "hf.co/Fixture/Repo:q4_k_m"]).code == 0)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }
}

private final class ModelTestBundle: NSObject {}

private struct RunnerFixture {
    static var canBindLoopback: Bool { (try? availablePort()) != nil }
    static func executableURL(testBundle: URL, override: String?) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override) }
        let products = testBundle.pathExtension == "xctest" ? testBundle.deletingLastPathComponent() : testBundle
        return products.appendingPathComponent("noodle")
    }

    let home: URL
    let port: Int
    private let executable: URL
    private let server: URL

    init(needsListener: Bool = true) throws {
        executable = Self.executableURL(testBundle: Bundle(for: ModelTestBundle.self).bundleURL,
            override: ProcessInfo.processInfo.environment["NOODLE_BIN"])
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Build noodle alongside the active tests or set NOODLE_BIN")
        home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-model-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        server = MLXServeRuntime.installation(in: home.appendingPathComponent("models")).appendingPathComponent("mlx-serve")
        do {
            try FileManager.default.createDirectory(at: server.deletingLastPathComponent().appendingPathComponent("lib"), withIntermediateDirectories: true)
            try Data().write(to: server.deletingLastPathComponent().appendingPathComponent("lib/libmlx.dylib"))
            try Data(Self.serverScript.utf8).write(to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
            let weights = home.appendingPathComponent("fixture.gguf")
            try (Data("GGUF".utf8) + Data(repeating: 0, count: 24)).write(to: weights)
            port = needsListener ? try Self.availablePort() : 11345
            let result = command(["import", weights.path, "fixture"])
            try #require(result.code == 0, Comment(rawValue: result.output))
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    func command(_ arguments: [String], environment: [String: String] = [:]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["model"] + arguments
        var values = ProcessInfo.processInfo.environment
        values.removeValue(forKey: "NOODLE_MODEL_KEEP_ALIVE")
        values["NOODLE_HOME"] = home.path
        values["NOODLE_LOCAL_NAMES"] = "0"
        values.merge(environment) { _, new in new }
        process.environment = values
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func serve(keepAlive: String, environment: [String: String] = [:]) throws {
        let result = command(["serve", "fixture", "--port", String(port), "--keep-alive", keepAlive],
                             environment: environment)
        try #require(result.code == 0, Comment(rawValue: result.output))
    }

    func eventually(seconds: Double = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// One pid per runtime start, appended by the fake runtime.
    func startedPIDs() -> [Int32] {
        ((try? String(contentsOf: home.appendingPathComponent("starts"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Int32($0) }
    }

    func supervisorPID() throws -> Int32 {
        let data = try Data(contentsOf: home.appendingPathComponent("models/session.json"))
        let session = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((session["process"] as? [String: Any])?["pid"] as? NSNumber).int32Value
    }

    func install(_ id: String, mlx: Bool = false) throws {
        let source = home.appendingPathComponent("input-" + id + (mlx ? ".mlx" : ".gguf"))
        if mlx {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: source.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer.json"))
            try Data(repeating: 0, count: 24).write(to: source.appendingPathComponent("model.safetensors"))
        } else {
            try (Data("GGUF".utf8) + Data(repeating: 0, count: 24)).write(to: source)
        }
        let result = command(["import", source.path, id])
        try #require(result.code == 0, Comment(rawValue: result.output))
    }

    func status() throws -> LocalModelStatus {
        let result = command(["status", "--json"])
        try #require(result.code == 0, Comment(rawValue: result.output))
        return try JSONDecoder().decode(LocalModelStatus.self, from: Data(result.output.utf8))
    }

    func endpoint() throws -> LocalModelEndpoint {
        let result = command(["endpoint", "--json"])
        try #require(result.code == 0, Comment(rawValue: result.output))
        return try JSONDecoder().decode(LocalModelEndpoint.self, from: Data(result.output.utf8))
    }

    func request(endpoint: LocalModelEndpoint, path: String, body: [String: Any]? = nil) throws -> URLRequest {
        let root = endpoint.baseURL.deletingLastPathComponent()
        var request = URLRequest(url: root.appendingPathComponent(path))
        request.timeoutInterval = 60
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func recordActiveSession(pid: Int32, keepAlive: LocalModelKeepAlive?) throws {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try #require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        _ = try saveSession(keepAlive: keepAlive, process: ["pid": pid, "seconds": info.pbi_start_tvsec,
                                                          "microseconds": info.pbi_start_tvusec])
        try Data("fixture-policy-key\n".utf8).write(to: home.appendingPathComponent("models/key"))
        try Data("Authorization: Bearer fixture-policy-key\n".utf8).write(to: home.appendingPathComponent("models/auth.header"))
    }

    /// The fake runtime records its arguments and parent pid, then idles like a server. `_exec` stays alive
    /// as its supervisor, so the test stops it with SIGTERM once the file appears.
    func captureLaunch(keepAlive: LocalModelKeepAlive) throws -> ([String], Int32, Int32) {
        let capture = home.appendingPathComponent("captured.json")
        try Data("#!/usr/bin/python3\nimport json, os, sys, time\nopen(sys.argv[0] + '.tmp', 'w').write(json.dumps({'arguments':sys.argv[1:],'pid':os.getppid()}))\nos.rename(sys.argv[0] + '.tmp', '\(capture.path)')\ntime.sleep(60)\n".utf8).write(to: server)
        let id = try saveSession(keepAlive: keepAlive)
        let sessionFile = home.appendingPathComponent("models/session.json")
        let launcher = Process()
        launcher.executableURL = executable
        launcher.arguments = ["model", "_exec", id]
        var values = ProcessInfo.processInfo.environment
        values["NOODLE_HOME"] = home.path
        values["NOODLE_LOCAL_NAMES"] = "0"
        launcher.environment = values
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        launcher.standardInput = FileHandle.nullDevice
        try launcher.run()
        defer {
            launcher.terminate()
            launcher.waitUntilExit()
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: capture.path) { Thread.sleep(forTimeInterval: 0.05) }
        let result = (output: String(decoding: (try? Data(contentsOf: capture)) ?? Data(), as: UTF8.self), code: Int32(0))
        struct Captured: Decodable { let arguments: [String]; let pid: Int32 }
        let captured = try JSONDecoder().decode(Captured.self, from: Data(result.output.utf8))
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sessionFile)) as? [String: Any])
        let process = try #require(saved["process"] as? [String: Any])
        let pid = try #require(process["pid"] as? NSNumber).int32Value
        return (captured.arguments, captured.pid, pid)
    }

    private func saveSession(keepAlive: LocalModelKeepAlive?, process: [String: Any]? = nil) throws -> String {
        let id = UUID().uuidString
        var session: [String: Any] = ["id": id, "model": "fixture", "host": "127.0.0.1", "port": port,
                                     "executable": server.path, "backend": "llama.cpp"]
        if let keepAlive { session["keepAlive"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(keepAlive)) }
        if let process { session["process"] = process }
        let key = String(repeating: "a", count: 64)
        try Data((key + "\n").utf8).write(to: home.appendingPathComponent("models/key"))
        try Data(("Authorization: Bearer " + key + "\n").utf8).write(to: home.appendingPathComponent("models/auth.header"))
        try JSONSerialization.data(withJSONObject: session).write(to: home.appendingPathComponent("models/session.json"))
        return id
    }

    func cleanUp() {
        for _ in 0..<4 { _ = command(["stop"]) }
        try? FileManager.default.removeItem(at: home)
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard result else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static let serverScript = #"""
    #!/usr/bin/python3
    import http.server, json, os, pathlib, sys, threading, time
    args = sys.argv
    test_home = pathlib.Path(os.environ['NOODLE_HOME'])
    with open(test_home / 'starts', 'a') as starts: starts.write(str(os.getpid()) + '\n')
    def crash_on_request():
        while True:
            if (test_home / 'crash-now').exists():
                (test_home / 'crash-now').unlink()
                os._exit(1)
            time.sleep(0.02)
    threading.Thread(target=crash_on_request, daemon=True).start()
    def option(name): return args[args.index(name) + 1]
    model_dirs = [pathlib.Path(args[i+1]) for i, a in enumerate(args) if a == '--model-dir']
    key = os.environ[option('--api-key-env')]
    loaded = set()
    def models():
        return [str(p.parent.relative_to(root)) for root in model_dirs for p in root.rglob('model.gguf')] + [p.name for root in model_dirs for p in root.iterdir() if p.is_symlink()]
    discovered = models()
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args): pass
        def respond(self, body, status=200, content_type='application/json'):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def authorized(self):
            if self.headers.get('Authorization') == 'Bearer ' + key: return True
            self.respond(b'{"error":"unauthorized"}', 401)
            return False
        def do_GET(self):
            if self.authorized(): self.respond(json.dumps({'data':[{'id':m, 'loaded':m in loaded} for m in discovered]}).encode())
        def do_POST(self):
            global discovered
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if not self.authorized(): return
            request = json.loads(body)
            model = request.get('model')
            if self.path == '/v1/models/rescan':
                discovered = models()
                self.respond(b'{}')
                return
            if self.path == '/v1/load-model':
                if model not in discovered or model == 'fail':
                    self.respond(b'{"error":"cannot load model"}', 400)
                    return
                loaded.add(model)
                self.respond(json.dumps({'model':{'id':model, 'loaded':True}}).encode())
                return
            if self.path == '/v1/unload-model':
                loaded.discard(model)
                if (pathlib.Path(os.environ['NOODLE_HOME']) / 'reload-on-unload').exists(): loaded.add(model)
                self.respond(json.dumps({'model':{'id':model, 'loaded':False}}).encode())
                return
            if request.get('stream'):
                first, last = b'data: {"choices":[]}\n\n', b'data: [DONE]\n\n'
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(first) + len(last)))
                self.end_headers()
                self.wfile.write(first)
                self.wfile.flush()
                home = pathlib.Path(os.environ['NOODLE_HOME'])
                (home / 'request-active').touch()
                deadline = time.monotonic() + 15
                while not (home / 'release-response').exists() and time.monotonic() < deadline: time.sleep(0.01)
                self.wfile.write(last)
                return
            self.respond(json.dumps({'choices':[{'message':{'content':'fixture reply: ' + str(model)}}]}).encode())
    http.server.ThreadingHTTPServer(('127.0.0.1', int(option('--port'))), Handler).serve_forever()
    """#
}
