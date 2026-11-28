import Darwin
import Foundation
import NoodleCore

struct ModelRunner {
    let store: ModelStore
    private let files = FileManager.default
    private var sessionFile: URL { store.directory.appendingPathComponent("session.json") }
    private var keyFile: URL { ModelAPIKey.keyFile(in: store.directory) }
    private var headerFile: URL { ModelAPIKey.headerFile(in: store.directory) }
    var log: URL { store.directory.appendingPathComponent("runner.log") }

    private func readSession() -> Session? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func save(_ session: Session) throws {
        try writePrivate(JSONEncoder().encode(session), to: sessionFile)
    }

    private func writePrivate(_ data: Data, to path: URL) throws {
        try data.write(to: path, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func liveSession() -> Session? {
        guard let session = readSession(), session.process?.isLive == true else { return nil }
        return session
    }

    private struct Record: Decodable {
        let id: String
        let loaded: Bool?
    }

    private func request(_ path: String, session: Session, at baseURL: URL? = nil,
                         body: [String: Any]? = nil, timeout: Int = 10) throws -> Data {
        guard let url = (baseURL ?? session.baseURL)?.appendingPathComponent(path) else {
            throw CLIError("invalid model endpoint")
        }
        var arguments = ["--disable", "--noproxy", "*", "--fail-with-body", "--silent", "--show-error",
                         "--max-time", String(timeout), "--header", "@\(headerFile.path)"]
        if let body {
            arguments += ["--header", "Content-Type: application/json", "--data-binary",
                          String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)]
        }
        let result = run("/usr/bin/curl", arguments + [url.absoluteString])
        guard result.code == 0 else { throw CLIError("model request failed: \(result.out.prefix(2048))") }
        return Data(result.out.utf8)
    }

    private func records(_ session: Session, at baseURL: URL? = nil) throws -> [Record] {
        struct Response: Decodable { let data: [Record] }
        return try JSONDecoder().decode(Response.self, from: request("models", session: session, at: baseURL, timeout: 1)).data
    }

    private func ready(_ session: Session, at baseURL: URL? = nil) -> Bool {
        (try? records(session, at: baseURL).contains { $0.id == MLXServeLaunch.modelID(session.model) }) == true
    }

    private func preload(_ model: String, session: Session) throws {
        _ = try request("models/rescan", session: session, body: [:])
        struct Response: Decodable { let model: Record }
        let data = try request("load-model", session: session,
                               body: ["model": MLXServeLaunch.modelID(model), "default": true], timeout: 180)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.model.id == MLXServeLaunch.modelID(model), response.model.loaded == true else {
            throw CLIError("model \(model) did not finish loading")
        }
    }

    func status() -> LocalModelStatus {
        guard var session = liveSession() else {
            // A runtime that gave up leaves its crash record behind.
            let crashed = readSession().flatMap { $0.lastCrash == nil ? nil : $0 }
            return LocalModelStatus(phase: .stopped, restarts: crashed?.restarts, lastCrash: crashed?.lastCrash)
        }
        let isReady = ready(session)
        // Polling status never creates a lease or starts the daemon. Cached names must still work.
        if !isReady || !ModelNameRoute.isEnabled(in: store.directory) || !namedRouteReady(session) {
            session.namedBaseURL = nil
        }
        return session.status(isReady ? .ready : .starting)
    }

    func endpoint() throws -> LocalModelEndpoint {
        guard liveSession() != nil else { throw CLIError("the model runner is not ready") }
        return try store.withLock("launch") {
            guard var session = liveSession(), let url = session.baseURL, ready(session) else {
                throw CLIError("the model runner is not ready")
            }
            session = refreshNamedRoute(session)
            let apiKey = try String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .newlines)
            guard liveSession()?.id == session.id else {
                throw CLIError("the model runner changed. Request the endpoint again.")
            }
            return LocalModelEndpoint(model: MLXServeLaunch.modelID(session.model), baseURL: url, workloadBaseURL: session.workloadBaseURL,
                                      apiKey: apiKey, backend: session.resolvedBackend, namedBaseURL: session.namedBaseURL)
        }
    }

    private func namedRouteReady(_ session: Session) -> Bool {
        guard let lease = session.namedRoute, let url = session.namedBaseURL,
              url == lease.baseURL, ModelNameRoute.daemonIdentity() == lease.daemon else { return false }
        return ready(session, at: url)
    }

    /// Caller holds the launch lock, so stop/relaunch cannot change credentials or lease ownership.
    private func refreshNamedRoute(_ original: Session) -> Session {
        var session = original
        var savedName = original.namedBaseURL
        session.namedBaseURL = nil
        guard ModelNameRoute.isEnabled(in: store.directory) else {
            if let lease = session.namedRoute { ModelNameRoute.unregister(lease) }
            session.namedRoute = nil
            if original.namedRoute != nil || original.namedBaseURL != nil { try? save(session) }
            return session
        }
        // The router forwards to loopback; an explicit bridge listener binds only that interface.
        guard session.host == "127.0.0.1",
              let daemon = ModelNameRoute.daemonIdentity() else { return session }
        let existingRouteReady = session.namedRoute.map {
            $0.daemon == daemon && ready(session, at: $0.baseURL)
        } ?? false
        if !existingRouteReady {
            // A route can be removed while its runner remains live. Recreate only our lease.
            if let lease = session.namedRoute, lease.daemon == daemon {
                ModelNameRoute.unregister(lease)
            }
            session.namedRoute = ModelNameRoute.register(session, daemon: daemon)
            // Persist the exact lease before probing DNS, so stop can always release it.
            do {
                try save(session)
                savedName = nil
            }
            catch {
                if let lease = session.namedRoute { ModelNameRoute.unregister(lease) }
                session.namedRoute = nil
                return session
            }
        }
        if let lease = session.namedRoute, existingRouteReady || ready(session, at: lease.baseURL),
           ModelNameRoute.daemonIdentity() == lease.daemon {
            session.namedBaseURL = lease.baseURL
        }
        if session.namedBaseURL != savedName { try? save(session) }
        return session
    }

    private func readyStatusWithName(_ original: Session) throws -> LocalModelStatus {
        try store.withLock("launch") {
            guard let session = liveSession(), session.id == original.id else {
                throw CLIError("the model runner changed. Request its status again.")
            }
            return refreshNamedRoute(session).status(.ready)
        }
    }

    /// Start or reuse the selected model before entering CLI chat.
    func ensureRunning(_ model: String, keepAlive: LocalModelKeepAlive? = nil) throws {
        try store.withLock("operation") {
            _ = try (keepAlive ?? .default).idleEvictSeconds()
            if !files.fileExists(atPath: try store.path(for: model).path) { try store.pull(model) }
            let previous = liveSession()
            _ = try serve(model, host: previous?.host ?? "127.0.0.1", port: previous?.port ?? ModelBinding.defaultPort,
                          keepAlive: keepAlive ?? previous?.keepAlive)
        }
    }

    func chat(_ messages: [LocalModelChat.Message], model: String) throws -> String {
        let endpoint = try endpoint()
        // Read the private request through an open descriptor. curl receives neither the prompt nor the key in argv.
        let file = store.directory.appendingPathComponent(".prompt-\(UUID().uuidString)")
        defer { try? files.removeItem(at: file) }
        try writePrivate(LocalModelChat.body(model: MLXServeLaunch.modelID(model), messages: messages), to: file)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try files.removeItem(at: file)
        let result = run("/usr/bin/curl", [
            "--disable", "--noproxy", "*", "--fail-with-body", "--silent", "--show-error", "--max-time", "120",
            "--header", "@\(headerFile.path)", "--header", "Content-Type: application/json", "--data-binary", "@-",
            endpoint.baseURL.appendingPathComponent("chat/completions").absoluteString,
        ], input: input)
        if result.code != 0, let refusal = LocalModelMemoryRefusal.userMessage(for: result.out) {
            throw CLIError(refusal)
        }
        guard result.code == 0 else { throw CLIError("the model could not answer. Check that it is still serving and try a shorter prompt.") }
        return try LocalModelChat.reply(from: Data(result.out.utf8))
    }

    func serve(_ model: String, host: String, port: Int, keepAlive: LocalModelKeepAlive? = nil) throws -> LocalModelStatus {
        let modelFile = try store.path(for: model)
        guard files.fileExists(atPath: modelFile.path) else {
            throw CLIError("model \(model) is not installed. Pull or import it first.")
        }
        try store.checkWeights(modelFile)
        let backend = try store.backend(for: model)
        let launchKeepAlive = ModelKeepAliveSetting.effective(explicit: keepAlive, root: store.directory.deletingLastPathComponent())
        _ = try launchKeepAlive.idleEvictSeconds()
        let launchSeconds: TimeInterval = 180
        let (session, created) = try store.withLock("launch") { () -> (Session, Bool) in
            // A saved session without a process is a launch in flight when it is recent.
            var existing = liveSession()
            if existing == nil { reapOrphan(readSession(), termSeconds: 10) }
            if existing == nil, let pending = readSession(), pending.process == nil, let at = pending.created,
               Date().timeIntervalSince(at) < launchSeconds { existing = pending }
            if let current = existing {
                guard current.host == host, current.port == port else {
                    throw CLIError("the model server is already running. Stop it before changing its address.")
                }
                if let keepAlive, keepAlive != (current.keepAlive ?? .default) {
                    throw CLIError("model \(model) is already running with a different keep-alive. Use 'noodle model stop' explicitly before changing its policy.")
                }
                return (current, false)
            }
            var config = Session(id: UUID().uuidString, model: model, host: host, port: port,
                                 executable: try ModelMLXRuntime.executable(store: store).path, backend: backend)
            config.created = Date()
            config.keepAlive = launchKeepAlive
            try ModelAPIKey.current(in: store.directory)
            try writePrivate(Data(), to: log)
            try save(config)
            return (config, true)
        }

        if created {
            let child = Process()
            child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: selfDirectory() + "/noodle")
            child.arguments = ["model", "_exec", session.id]
            child.standardInput = FileHandle.nullDevice
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            child.standardOutput = output
            child.standardError = output
            try child.run()
            let deadline = Date().addingTimeInterval(launchSeconds)
            while child.isRunning, Date() < deadline {
                if let current = liveSession(), current.id == session.id, ready(current) {
                    do {
                        try store.withLock("launch") { try preload(model, session: current) }
                        return try readyStatusWithName(current)
                    } catch {
                        try? stop(onlyID: session.id)
                        throw error
                    }
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            try? stop(onlyID: session.id)
            throw CLIError("model runner did not become ready. See 'noodle model logs'.")
        }
        guard waitFor({ ready(session) }, seconds: launchSeconds) else {
            throw CLIError("model runner is not ready. See 'noodle model logs'.")
        }
        return try store.withLock("launch") {
            guard var current = liveSession(), current.id == session.id else {
                throw CLIError("the model runner changed while loading")
            }
            try ModelMLXRuntime.prepareModels(store: store)
            try preload(model, session: current)
            current.model = model
            current.backend = backend
            try save(current)
            return refreshNamedRoute(current).status(.ready)
        }
    }

    func refreshModels() throws {
        try store.withLock("launch") {
            guard let session = liveSession() else { return }
            try ModelMLXRuntime.prepareModels(store: store)
            _ = try request("models/rescan", session: session, body: [:])
        }
    }

    func stop(onlyID: String? = nil, allModels: Bool = false) throws {
        try store.withLock("launch") {
            let recorded = readSession()
            if let onlyID, recorded?.id != onlyID { return }
            if liveSession() == nil { reapOrphan(recorded, termSeconds: 10) }
            if var session = liveSession(), let process = session.process {
                if onlyID == nil && !allModels {
                    _ = try request("unload-model", session: session, body: ["model": MLXServeLaunch.modelID(session.model)], timeout: 180)
                    let stopped = MLXServeLaunch.modelID(session.model)
                    if let next = try records(session).first(where: { $0.loaded == true && $0.id != stopped }) {
                        let local = store.list(includeCatalog: false).first { MLXServeLaunch.modelID($0.id) == next.id }
                        session.model = local?.id ?? next.id
                        session.backend = local?.backend
                        try preload(session.model, session: session)
                        try save(session)
                        return
                    }
                }
                let target = session.ownsProcessGroup == true ? -process.pid : process.pid
                if kill(target, SIGTERM) != 0, errno != ESRCH { throw modelPOSIXError() }
                let gone: () -> Bool = { !process.isLive && (target > 0 || kill(target, 0) != 0) }
                if !waitFor(gone, seconds: 60) {
                    // A hung runtime ignores SIGTERM; escalate so Stop always works.
                    _ = kill(target, SIGKILL)
                }
                guard waitFor(gone, seconds: 5) else {
                    throw CLIError("model runner is still stopping. Retry 'noodle model stop'.")
                }
            }
            if let lease = recorded?.namedRoute { ModelNameRoute.unregister(lease) }
            // The key outlives the server so other devices keep working across restarts.
            if files.fileExists(atPath: sessionFile.path) { try files.removeItem(at: sessionFile) }
        }
    }

    /// Restarts a running server with its model, address and keep-alive so a new key or network setting applies.
    /// Returns false when nothing was running. Caller holds the operation lock.
    @discardableResult
    func restart() throws -> Bool {
        guard let session = liveSession() else { return false }
        try stop(allModels: true)
        _ = try serve(session.model, host: session.host, port: session.port, keepAlive: session.keepAlive)
        return true
    }

    func remove(_ model: String) throws {
        try store.withLock("launch") {
            if let session = liveSession() {
                let inUse: Bool
                if session.model == model { inUse = true } else {
                    inUse = try records(session).contains { $0.id == MLXServeLaunch.modelID(model) && $0.loaded == true }
                }
                guard !inUse else { throw CLIError("stop \(model) before removing its weights") }
            }
            try store.remove(model)
            let folder = MLXServeLaunch.modelDirectories(in: store.directory)[model.hasPrefix("hf.co/") ? 1 : 0]
            let link = folder.appendingPathComponent(MLXServeLaunch.modelID(model))
            try? files.removeItem(at: link)
        }
    }

    /// The last ~20 lines of the runtime log, read from the file's tail.
    private func logTail(lines count: Int = 20) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
    }

    /// The runtime outlives a SIGKILLed supervisor and keeps its port. The recorded process group still names it.
    /// Never waits: a Stop in progress holds the launch lock for up to a minute while it waits for this process.
    private func recordCrash(_ id: String, note: String? = nil, restarting: Bool) {
        guard !runnerStopping else { return }
        let detail = ([note].compactMap { $0 } + [logTail()]).joined(separator: "\n")
        let fd = open(store.directory.appendingPathComponent("launch.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, var session = readSession(), session.id == id else { return }
        if restarting { session.restarts = (session.restarts ?? 0) + 1 }
        session.lastCrash = detail
        try? save(session)
    }

    /// Marks the runtime ready and, after a restart, reloads the selected model. A newer generation retires this thread.
    private func afterStart(_ id: String, generation: Int, watch: RunnerWatch) {
        let stale = { watch.generation != generation || runnerStopping }
        let answered = waitFor({ stale() || (readSession().map { ready($0) } ?? false) }, seconds: 180)
        guard !stale() else { return }
        guard answered else { return fail(id, "the restarted model runtime did not become ready") }
        watch.markReady()
        guard generation > 1 else { return }
        do {
            try store.withLock("launch") {
                guard !stale(), let session = liveSession(), session.id == id else { return }
                try preload(session.model, session: session)
            }
        } catch { fail(id, "reloading the model after a restart failed: \(error.localizedDescription)") }
    }

    private func fail(_ id: String, _ note: String) {
        err(note)
        recordCrash(id, note: note, restarting: false)
    }

    /// Stays alive as the runtime's parent (same process group, so Stop still reaches both) and restarts it
    /// when it exits without a stop request, once it has answered at least once.
    private func supervise(_ session: Session, arguments: [String]) throws {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber) { _ in
                runnerStopping = true
                if runnerChild > 0 { kill(runnerChild, SIGTERM) }
            }
        }
        // The environment hook lets tests use short backoff.
        var policy = MLXServeCrashPolicy(baseDelay: env["NOODLE_MODEL_RESTART_BASE_DELAY"].flatMap(Double.init) ?? 1)
        let watch = RunnerWatch()
        while !runnerStopping {
            // posix_spawn keeps the child in this process group; Foundation's Process starts its own.
            var argv = arguments.map { strdup($0) } + [nil]
            defer { for argument in argv { free(argument) } }
            var childPID: pid_t = 0
            let spawned = posix_spawn(&childPID, arguments[0], nil, nil, argv, environ)
            guard spawned == 0 else {
                fail(session.id, "could not start the model runtime: \(String(cString: strerror(spawned)))")
                throw CLIError("could not start the model runtime")
            }
            runnerChild = childPID
            if runnerStopping { kill(childPID, SIGTERM) }
            let generation = watch.next()
            nonisolated(unsafe) let runner = self
            Thread.detachNewThread { runner.afterStart(session.id, generation: generation, watch: watch) }
            var waitStatus: Int32 = 0
            while waitpid(childPID, &waitStatus, 0) < 0, errno == EINTR {}
            runnerChild = 0
            guard !runnerStopping, readSession()?.id == session.id else { return }
            let status = waitStatus & 0x7f == 0 ? "exit \((waitStatus >> 8) & 0xff)" : "signal \(waitStatus & 0x7f)"
            guard watch.everReady else {
                fail(session.id, "the model runtime exited (\(status)) before it answered")
                return
            }
            guard case .restart(let delay) = policy.recordCrash(at: Date()) else {
                recordCrash(session.id, restarting: false)
                err("model runtime keeps crashing; giving up")
                return
            }
            recordCrash(session.id, restarting: true)
            err("model runtime exited (\(status)); restarting in \(delay)s")
            let end = Date().addingTimeInterval(delay)
            while Date() < end, !runnerStopping, readSession()?.id == session.id { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    func launch(_ id: String) throws {
        let (session, arguments) = try store.withLock("launch") { () -> (Session, [String]) in
            guard var session = readSession(), session.id == id, session.process == nil,
                  let identity = ProcessIdentity.read(getpid()) else {
                throw CLIError("the model launch request is no longer current")
            }
            if session.host != "127.0.0.1" { try ModelBinding.requireVMBridge(session.host) }
            let weights = try store.path(for: session.model)
            try store.checkWeights(weights)
            guard getpgrp() == getpid() || setpgid(0, 0) == 0 else { throw modelPOSIXError() }
            session.process = identity
            session.ownsProcessGroup = true
            try save(session)
            let key = try String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .newlines)
            let arguments = try ModelMLXRuntime.arguments(executable: session.executable, host: session.host, port: session.port,
                                                        keepAlive: session.keepAlive ?? .default,
                                                        backend: session.backend ?? .llamaCPP, store: store)
            // The runtime retains this pid after exec. The Mac loopback relay refuses its owned port.
            NoodleOwnedPorts.shared.claim(session.port, forProcess: getpid())
            try ModelMLXRuntime.applyEnvironment(key: key, store: store)
            return (session, arguments)
        }
        try supervise(session, arguments: arguments)
    }
}

// Set from the signal handler; the supervisor is the only user.
nonisolated(unsafe) private var runnerStopping = false
nonisolated(unsafe) private var runnerChild: pid_t = 0

/// Which runtime start is current, and whether any start has answered yet. Shared with the watcher threads.
private final class RunnerWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var answered = false
    var generation: Int { lock.withLock { current } }
    var everReady: Bool { lock.withLock { answered } }
    func next() -> Int { lock.withLock { current += 1; return current } }
    func markReady() { lock.withLock { answered = true } }
}
