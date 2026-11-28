import SwiftUI
import NoodleCore

struct DockerSettings: View {
    let env: AppEnvironment
    @State private var tool: String?
    @State private var context = "default"
    @State private var chosenContext = "default"
    @State private var contexts: [String] = []
    @State private var builder: String?
    @State private var chosenBuilder = ""
    @State private var builders: [String] = []
    @State private var notice: String?
    @State private var busy = false
    @State private var confirmingPrune = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Docker commands go to", value: env.connection.dockerTarget ?? "—")
                Picker("Context", selection: $chosenContext) {
                    ForEach(contexts, id: \.self) { Text($0).tag($0) }
                }
                Button("Switch Context") { Task { await switchContext() } }
                    .disabled(busy || tool == nil || context == chosenContext)
            } header: {
                Text("Docker CLI")
            } footer: {
                Text("Sets where plain docker commands go. DOCKER_HOST or DOCKER_CONTEXT set in a shell still wins. Containers stay on the engine that started them.")
            }
            Section {
                if builders.isEmpty {
                    Text("No Buildx builders found. Install the Docker CLI and Buildx to choose one.").foregroundStyle(.secondary)
                } else {
                    Picker("Buildx builder", selection: $chosenBuilder) {
                        if !builders.contains(chosenBuilder) { Text("Choose a builder").tag("") }
                        ForEach(builders, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Use Builder") { Task { await switchBuilder() } }
                        .disabled(busy || chosenBuilder.isEmpty || chosenBuilder == builder)
                }
            } header: {
                Text("Builder")
            } footer: {
                Text("Applies to docker buildx build. Plain docker build uses the engine’s default builder.")
            }
            RegistrySettings(docker: tool, demo: env.demo)
            BrowserSignInSection(providers: BrowserSignIn.Provider.allCases, docker: tool, demo: env.demo)
            Section("Build cache") {
                Button("Check Cache Usage") { Task { await cache(prune: false) } }.disabled(busy || tool == nil)
                Button("Clear Unused Cache…") { confirmingPrune = true }.disabled(busy || tool == nil)
            }
            if busy { ProgressView().controlSize(.small) }
            if let notice { Text(notice).font(.callout).textSelection(.enabled) }
            Button("Refresh") { Task { await reload() } }.disabled(busy)
        }
        .formStyle(.grouped)
        .task { await reload() }
        .confirmationDialog("Clear unused Noodle build cache?", isPresented: $confirmingPrune, titleVisibility: .visible) {
            Button("Clear Unused Cache", role: .destructive) { Task { await cache(prune: true) } }
        } message: {
            Text("The next build may take longer. Images and containers stay in place.")
        }
    }

    private func reload() async {
        if env.demo {
            contexts = ["default", "noodle"]
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let paths = env.paths
        let snapshot = await Task.detached {
            (SetupProbe.discovery(paths).docker(), DockerSettingsCommands.contexts())
        }.value
        tool = snapshot.0
        context = snapshot.1.saved
        chosenContext = context
        contexts = snapshot.1.names
        await env.sync.refreshDockerTarget()
        await loadBuilders()
    }

    private func loadBuilders() async {
        guard let tool, !context.hasPrefix("-") else { return }
        let list = await DockerSettingsCommands.run(tool, ["--context", context, "buildx", "ls", "--format", "json"])
        guard !Task.isCancelled else { return }
        builders = list.code == 0 ? DockerSettingsCommands.builderNames(list.output) : []
        guard !builders.isEmpty else { builder = nil; chosenBuilder = ""; return }
        let active = await DockerSettingsCommands.run(tool, ["--context", context, "buildx", "inspect"])
        guard !Task.isCancelled else { return }
        builder = active.code == 0 ? DockerSettingsCommands.builderName(active.output) : nil
        chosenBuilder = builder.flatMap { builders.contains($0) ? $0 : nil } ?? ""
    }

    private func switchContext() async {
        guard !busy, let tool else { return }
        busy = true
        defer { busy = false }
        let requested = chosenContext
        let result = await DockerSettingsCommands.selectContext(requested, docker: tool, socket: env.paths.socket.path)
        notice = DockerSettingsCommands.message(result, fallback: "Could not switch Docker context.")
        if result.code == 0 {
            let settings = await Task.detached { DockerSettingsCommands.contexts() }.value
            context = settings.saved
            chosenContext = context
            contexts = settings.names
            await env.sync.refreshDockerTarget()
            await loadBuilders()
        }
    }

    private func switchBuilder() async {
        guard !busy, let tool, builders.contains(chosenBuilder),
              !chosenBuilder.hasPrefix("-"), !context.hasPrefix("-") else { return }
        busy = true
        defer { busy = false }
        let requested = chosenBuilder
        let result = await DockerSettingsCommands.run(tool, ["--context", context, "buildx", "use", requested])
        notice = result.code == 0 ? "Selected \(requested) for \(context)." : DockerSettingsCommands.message(result, fallback: "Could not select the builder.")
        if result.code == 0 { await loadBuilders() }
    }

    private func cache(prune: Bool) async {
        guard !busy, let tool else { return }
        busy = true
        defer { busy = false }
        let result = await DockerSettingsCommands.cache(prune: prune, docker: tool, paths: env.paths)
        notice = DockerSettingsCommands.message(result, fallback: "The builder returned no cache information.")
    }
}

enum DockerSettingsCommands {
    static func contexts() -> (saved: String, names: [String]) {
        let config = SetupProbe.dockerContexts(ProcessInfo.processInfo.environment)
        let current = config.current ?? "default"
        let names = Set(config.endpoints.map(\.name) + ["default", "noodle", current])
        return (current, names.sorted())
    }

    static func run(_ docker: String, _ arguments: [String], timeout: TimeInterval = 20) async -> CLI.Result {
        var environment = ProcessInfo.processInfo.environment
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "BUILDX_BUILDER", "BUILDKIT_HOST"] { environment[key] = nil }
        return await CLI.stream(executable: docker, arguments, environment: environment, timeout: timeout) { _ in }
    }

    static func selectContext(_ name: String, docker: String, socket: String) async -> CLI.Result {
        guard !name.hasPrefix("-") else { return .init(code: 2, output: "Invalid Docker context.") }
        if name == "noodle" {
            let config = await Task.detached { SetupProbe.dockerContexts(ProcessInfo.processInfo.environment) }.value
            if let host = config.endpoints.first(where: { $0.name == name })?.host {
                let expected = URL(fileURLWithPath: socket).resolvingSymlinksInPath()
                let configured = (try? ImportNaming.socketPath(host: host)).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
                guard configured == expected else { return .init(code: 2, output: "The noodle context points to a different socket. Run noodle doctor --fix in a terminal to repair it.") }
            } else {
                // With the description `noodle setup` writes, so doctor and uninstall recognise the context as Noodle's.
                let created = await addContext(docker: docker, socket: socket)
                guard created.code == 0 else { return created }
            }
        }
        return await run(docker, ["context", "use", name])
    }

    /// Adds the `noodle` context and nothing else. The selected context stays as it is.
    static func addContext(docker: String, socket: String) async -> CLI.Result {
        await run(docker, ["context", "create", "noodle", "--description", "Noodle", "--docker", "host=unix://" + socket])
    }

    static func builderNames(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = object["Name"] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    static func builderName(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Name:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
    }

    static func message(_ result: CLI.Result, fallback: String) -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : String(text.suffix(4096))
    }

    /// A separate Docker config makes the implicit default builder belong to this exact socket.
    /// A saved builder name or shell override cannot redirect the cache operation to another engine.
    static func cache(prune: Bool, docker: String, paths: NoodlePaths) async -> CLI.Result {
        let plugin = await Task.detached {
            let discovery = SetupProbe.discovery(paths)
            return discovery.candidates("docker-buildx", includeManaged: true)
                .first { discovery.compatible($0, name: "docker-buildx") }
        }.value
        guard let plugin else { return .init(code: 127, output: "Docker Buildx is unavailable. Run Noodle setup to locate or install it.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let pluginDirectory = URL(fileURLWithPath: plugin).deletingLastPathComponent().path
            let config = try JSONEncoder().encode(["cliPluginsExtraDirs": [pluginDirectory]])
            try config.write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            var environment = SetupProbe.dockerEnvironment(socket: paths.socket.path)
            for key in ["BUILDX_CONFIG", "BUILDX_BUILDER", "BUILDKIT_HOST", "DOCKER_API_VERSION"] { environment[key] = nil }
            environment["DOCKER_CONFIG"] = directory.path
            let arguments = ["buildx", prune ? "prune" : "du", "--builder", "default"] + (prune ? ["--force"] : [])
            return await CLI.stream(executable: docker, arguments, environment: environment, timeout: 90) { _ in }
        } catch {
            return .init(code: 1, output: error.localizedDescription)
        }
    }
}
