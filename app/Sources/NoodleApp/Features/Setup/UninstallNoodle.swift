import Foundation
import Observation
import NoodleCore

enum UninstallNoodle {
    static let previousContextKey = "setupPreviousDockerContext"
    static let removals = [
        "Stops Noodle’s container engine and model runner, and removes its LaunchAgents.",
        "Removes the noodle Docker context. If selected, restores the context saved by app setup, or default.",
        "Removes Noodle-owned CLI copies and links, including Compose and Buildx links.",
        "Removes the PATH block setup added to your shell profile, the Docker socket and the setup information.",
    ]

    static func arguments(deleteData: Bool) -> [String] {
        ["uninstall"] + (deleteData ? ["--delete-data", "--yes"] : [])
    }

    static func resolvedDataPath(_ root: URL) -> String { root.resolvingSymlinksInPath().standardizedFileURL.path }

    static func ownsContext(_ data: Data?, socket: String, recordedEndpoint: String?) -> Bool {
        guard let data, let context = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              context["Name"] as? String == "noodle",
              (context["Metadata"] as? [String: Any])?["Description"] as? String == "Noodle",
              let endpoint = (((context["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String) else { return false }
        return endpoint == "unix://" + socket || endpoint == recordedEndpoint
    }

    static func restoreContext(current: String?, previous: String?, available: [String], owned: Bool) -> String? {
        guard owned, current == "noodle", let previous, previous != "noodle", !previous.hasPrefix("-"),
              previous == "default" || available.contains(previous) else { return nil }
        return previous
    }

    /// Discovery and process execution stay off the main actor. Packaged apps always use their bundled CLI.
    static func run(_ arguments: [String]) async -> CLI.Result {
        let previous = UserDefaults.standard.string(forKey: previousContextKey)
        let snapshot = await Task.detached {
            let fm = FileManager.default
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/noodle")
            let cli = Bundle.main.bundleURL.pathExtension == "app"
                ? (fm.isExecutableFile(atPath: bundled.path) ? bundled : nil) : CLI.locate()
            let config = SetupProbe.dockerContexts(ProcessInfo.processInfo.environment)
            let environment = ProcessInfo.processInfo.environment
            let dockerConfig = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
                ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.docker"
            let paths = NoodlePaths.resolve()
            let receipt = (try? Data(contentsOf: paths.root.appendingPathComponent("setup.json")))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            let hash = String(Digest.sha256(Data("noodle".utf8)).dropFirst(7))
            let metadata = try? Data(contentsOf: URL(fileURLWithPath: dockerConfig).appendingPathComponent("contexts/meta/\(hash)/meta.json"))
            let owned = ownsContext(metadata, socket: paths.socket.path, recordedEndpoint: receipt?["context:" + dockerConfig])
            let restore = restoreContext(current: config.current, previous: previous, available: config.endpoints.map(\.name), owned: owned)
            let docker = restore == nil ? nil : SetupProbe.discovery(NoodlePaths.resolve()).docker()
            return (cli, restore, docker)
        }.value
        guard let cli = snapshot.0 else { return .init(code: 127, output: "The bundled noodle command line tool was not found.") }
        var restored = ""
        if let context = snapshot.1 {
            guard let docker = snapshot.2 else { return .init(code: 127, output: "Docker CLI unavailable. Restore your previous Docker context before uninstalling.") }
            // Restore before --delete-data can remove the managed Docker executable.
            let result = await DockerSettingsCommands.run(docker, ["context", "use", context])
            guard result.code == 0 else { return result }
            restored = "Restored Docker context: \(context)\n"
        }
        let result = await invoke(executable: cli, arguments: arguments)
        return .init(code: result.code, output: restored + result.output)
    }

    /// Deleting data has no fixed deadline and must finish even if its presenting task is cancelled.
    static func invoke(executable: URL, arguments: [String]) async -> CLI.Result {
        await Task.detached { BoundedInvocation().run(executable: executable, arguments: arguments, timeout: nil) }.value
    }
}

@MainActor @Observable
final class UninstallFlow {
    var deleteData = false
    private(set) var running = false
    private(set) var result: CLI.Result?
    private let run: @Sendable ([String]) async -> CLI.Result

    init(run: @escaping @Sendable ([String]) async -> CLI.Result = UninstallNoodle.run) { self.run = run }

    var succeeded: Bool { result?.code == 0 }

    func uninstall() async {
        guard !running, !succeeded else { return }
        running = true
        result = nil
        result = await run(UninstallNoodle.arguments(deleteData: deleteData))
        running = false
    }
}
