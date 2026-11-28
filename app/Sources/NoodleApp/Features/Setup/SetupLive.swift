import Foundation
import NoodleCore

/// The real thing: the `noodle` CLI, the Docker command and Noodle's socket.
@MainActor
final class LiveSetupBackend: SetupBackend {
    private let env: AppEnvironment
    private var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    private var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    init(env: AppEnvironment) { self.env = env }

    var terminalPath: String { ((CLI.locate()?.path ?? "noodle") as NSString).abbreviatingWithTildeInPath }

    func detect() async -> SetupDetection {
        let paths = env.paths, home = home, shell = shell
        let inspection = Task.detached {
            (SetupProbe.detectTools(paths), SetupProbe.contexts(), SetupProbe.pathNeeded(home: home, shell: shell),
             SetupProbe.dockerOverride(home: home, shell: shell))
        }
        let local = await withTaskCancellationHandler { await inspection.value } onCancel: { inspection.cancel() }
        var engines: [SetupEngine] = []
        for context in local.1.list {
            guard !Task.isCancelled else { break }
            let api = DockerAPI(path: context.socket)
            let up = (try? await api.ping()) != nil
            guard !Task.isCancelled else { break }
            // Counted over the engine's own socket, read-only. It is never started or changed.
            let inventory = up ? await SetupProbe.inventory(api) : nil
            engines.append(SetupEngine(name: context.name, socket: context.socket, reachable: up,
                                       inUse: up && context.name == local.1.current, inventory: inventory))
        }
        return SetupDetection(tools: local.0, engines: engines, shell: shell, pathNeeded: local.2, dockerOverride: local.3)
    }

    func sizes(of names: [String]) async -> [String: Int64] {
        let mirror = ProcessInfo.processInfo.environment["NOODLE_TOOLS_MIRROR"].flatMap { $0.isEmpty ? nil : $0 }
        let pins = Tools.pins.filter { names.contains($0.name) }
        return await withTaskGroup(of: (String, Int64?).self) { group in
            for pin in pins { group.addTask { (pin.name, await SetupProbe.downloadSize(pin.url(mirror: mirror))) } }
            var table: [String: Int64] = names.contains("docker") ? ["docker": 19_641_900] : [:]
            for await (name, size) in group { if let size { table[name] = size } }
            return table
        }
    }

    func install(_ args: [String]) async -> CLI.Result {
        return await env.runSetup(args)
    }

    func downloadedFiles() -> [String: Int64] { SetupProbe.downloadFiles(env.paths) }

    func discardPartialDownloads() { SetupProbe.clearPartialDownloads(env.paths) }

    func startAndVerify(wantsPath: Bool, waiting: @MainActor (SetupApplyWait) -> Void) async -> SetupFacts {
        // Page-owned work must cancel when the assistant closes, including its readiness wait.
        waiting(.socket)
        _ = await CLI.run(["start"], timeout: 60)
        guard !Task.isCancelled else { return SetupFacts(dockerPath: nil, daemonUp: false, dockerReachesNoodle: false) }
        var up = (try? await env.service.ping()) != nil
        for _ in 0..<40 where !up {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            guard !Task.isCancelled else { break }
            up = (try? await env.service.ping()) != nil
        }
        guard !Task.isCancelled else { return SetupFacts(dockerPath: nil, daemonUp: up, dockerReachesNoodle: false) }
        let paths = env.paths, home = home, shell = shell
        let docker = await Task.detached { SetupProbe.discovery(paths).docker() }.value
        var reaches = false
        if up, let docker {
            waiting(.dockerVersion)
            let probe = await CLI.stream(executable: docker, ["version", "--format", "{{.Server.Version}}"],
                                         environment: SetupProbe.dockerEnvironment(socket: paths.socket.path), timeout: 20) { _ in }
            reaches = probe.code == 0
        }
        // Verify what a new Terminal would run, not only the docker setup found: a broken file ahead of it wins there.
        if wantsPath { waiting(.terminal) }
        let terminal = wantsPath ? await SetupProbe.terminalFacts(home: home, shell: shell) : nil
        return SetupFacts(dockerPath: docker, daemonUp: up, dockerReachesNoodle: reaches,
                          pathApplied: terminal?.applied, pathConflict: terminal?.conflict)
    }

    func runImport(_ source: String, flags: [String]) async -> CLI.Result {
        await SetupImportInvocation.run(source, flags: flags)
    }

    private func docker(_ args: [String], timeout: TimeInterval, onLine: @escaping @Sendable (String) -> Void) async -> CLI.Result {
        let paths = env.paths
        guard let docker = await Task.detached(operation: { SetupProbe.discovery(paths).docker() }).value else {
            return CLI.Result(code: 127, output: "Docker CLI unavailable.")
        }
        return await CLI.stream(executable: docker, args, environment: SetupProbe.dockerEnvironment(socket: paths.socket.path),
                                timeout: timeout, onLine: onLine)
    }

    func pull(onLine: @escaping @Sendable (String) -> Void) async -> CLI.Result {
        await docker(["pull", "alpine"], timeout: 600, onLine: onLine)
    }

    func runContainer() async -> (result: CLI.Result, milliseconds: Int) {
        let start = ContinuousClock.now
        let result = await docker(["run", "--rm", "alpine", "echo", SetupFlow.greeting], timeout: 120) { _ in }
        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return (result, ms)
    }

    func checkCompose() async -> CLI.Result {
        let paths = env.paths
        guard let docker = await Task.detached(operation: { SetupProbe.discovery(paths).docker() }).value else {
            return CLI.Result(code: 127, output: "Docker CLI unavailable.")
        }
        let environment = ProcessInfo.processInfo.environment
        let config = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker"
        return await SetupComposeCheck.verify(docker: docker, configDirectory: config)
    }
}
