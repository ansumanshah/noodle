import Foundation
import NoodleCore
import Observation

/// Install, update and remove run `docker compose` against the project `noodle-app-<id>`. Stop and Start reuse the
/// Containers page's project actions. Installed state is never stored here: it is read from the project label.
@MainActor @Observable
final class AIAppsStore {
    typealias Compose = @Sendable (_ arguments: [String], _ onLine: @escaping @Sendable (String) -> Void) async -> CLI.Result

    let catalog: [AIApp]
    private(set) var progress: [String: String] = [:]
    var error: String?
    /// Remove asks two separate questions: remove the app, then keep or delete its data.
    var confirmRemove: AIApp?
    var askDeleteData: AIApp?

    @ObservationIgnored private let containers: ContainersModel
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let wiring: @Sendable () async throws -> AIApp.ModelWiring
    @ObservationIgnored private let compose: Compose

    init(catalog: [AIApp], containers: ContainersModel, directory: URL,
         wiring: @escaping @Sendable () async throws -> AIApp.ModelWiring, compose: @escaping Compose) {
        self.catalog = catalog
        self.containers = containers
        self.directory = directory
        self.wiring = wiring
        self.compose = compose
    }

    func state(_ app: AIApp) -> AIAppState { app.state(in: containers.items) }
    func url(_ app: AIApp) -> URL { app.openURL(in: containers.items, names: containers.names) }
    func busy(_ app: AIApp) -> Bool { progress[app.id] != nil }

    // MARK: - Actions

    func install(_ app: AIApp, update: Bool = false) async {
        await run(app, first: update ? String(localized: "Checking for a newer version…") : String(localized: "Getting ready…")) {
            let model = app.usesModel ? try await self.wiring() : nil
            let folder = self.directory.appendingPathComponent(app.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("compose.yaml")
            // The file holds the model address, which is a credential: owner-only.
            try Data(app.render(model: model).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return ["--progress", "plain", "-p", app.project, "-f", file.path, "up", "-d", "--pull", update ? "always" : "missing"]
        }
    }

    func remove(_ app: AIApp, deleteData: Bool) async {
        await run(app, first: String(localized: "Removing…")) {
            ["-p", app.project, "down", "--remove-orphans"] + (deleteData ? ["--volumes"] : [])
        }
        if !deleteData || error == nil { try? FileManager.default.removeItem(at: directory.appendingPathComponent(app.id)) }
    }

    func start(_ app: AIApp) async { await containers.perform(.start, project: app.project) }
    func stop(_ app: AIApp) async { await containers.perform(.stop, project: app.project) }

    private func run(_ app: AIApp, first: String, arguments: @escaping () async throws -> [String]) async {
        guard !busy(app) else { return }
        error = nil
        Motion.animate { progress[app.id] = first }
        defer { Motion.animate { progress[app.id] = nil } }
        do {
            let args = try await arguments()
            let id = app.id
            let result = await compose(args) { [weak self] line in
                guard let words = AIAppProgress.words(for: line) else { return }
                Task { @MainActor in if self?.progress[id] != nil { self?.progress[id] = words } }
            }
            if result.code != 0 {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                error = String(localized: "\(app.name) didn't finish. \(String(detail.suffix(400)))")
            }
        } catch {
            self.error = error.localizedDescription
        }
        try? await containers.refresh()
    }
}

// MARK: - Live wiring

extension AIAppsStore {
    /// The real store: the `docker` CLI against Noodle's socket, and the model address from the engine.
    static func live(env: AppEnvironment) -> AIAppsStore {
        let paths = env.paths, service = env.service, demo = env.demo
        let directory = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("noodle-demo-apps")
                             : paths.root.appendingPathComponent("apps")
        return AIAppsStore(
            catalog: AICatalog.bundled().apps, containers: env.containers, directory: directory,
            wiring: {
                let connection = try await service.modelConnection()
                let model = await MainActor.run { env.modelsStore.status.model ?? env.modelsStore.selectedModel?.id }
                return .init(baseURL: connection.host + "/v1", modelID: model ?? "local")
            },
            compose: liveCompose(env: env))
    }

    /// `docker compose` against Noodle's socket; the demo only pretends, so captures never touch Docker.
    static func liveCompose(env: AppEnvironment) -> Compose {
        let paths = env.paths, demo = env.demo
        return { arguments, onLine in
            if demo {
                onLine("Pulling")
                try? await Task.sleep(for: .seconds(1.2))
                return .init(code: 0, output: "")
            }
            guard let docker = await Task.detached(operation: { SetupProbe.discovery(paths).docker() }).value else {
                return .init(code: 127, output: String(localized: "Docker command line tool not found. Run noodle tools install."))
            }
            return await CLI.stream(executable: docker, ["compose"] + arguments,
                                    environment: SetupProbe.dockerEnvironment(socket: paths.socket.path),
                                    timeout: 1800, onLine: onLine)
        }
    }
}
