import NoodleCore
import SwiftUI

/// Ready-to-paste setups for coding tools that talk to the local server.
enum ModelConnectApp: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code", codex = "Codex", cursor = "Cursor", continueDev = "Continue"
    var id: Self { self }

    /// `baseURL` ends in /v1. Claude Code adds /v1/messages itself, so it gets the server root.
    func snippet(baseURL: URL, key: String, model: String) -> String {
        let v1 = baseURL.absoluteString
        switch self {
        case .claudeCode:
            let root = v1.hasSuffix("/v1") ? String(v1.dropLast(3)) : v1
            return """
            export ANTHROPIC_BASE_URL=\(root)
            export ANTHROPIC_AUTH_TOKEN=\(key)
            export ANTHROPIC_MODEL=\(model)
            export ANTHROPIC_DEFAULT_HAIKU_MODEL=\(model)
            export ANTHROPIC_SMALL_FAST_MODEL=\(model)
            claude
            """
        case .codex:
            return """
            # ~/.codex/config.toml, then: export NOODLE_API_KEY=\(key)
            model = "\(model)"
            model_provider = "noodle"

            [model_providers.noodle]
            name = "Noodle"
            base_url = "\(v1)"
            env_key = "NOODLE_API_KEY"
            wire_api = "responses"
            """
        case .cursor:
            return """
            Settings > Models > OpenAI API Key, then Override OpenAI Base URL
            Base URL: \(v1)
            API key: \(key)
            Model: \(model)
            """
        case .continueDev:
            return """
            # ~/.continue/config.yaml
            name: Noodle
            version: 1.0.0
            schema: v1
            models:
              - name: Noodle
                provider: openai
                model: \(model)
                apiBase: \(v1)
                apiKey: \(key)
            """
        }
    }
}

struct ModelConnectApps: View {
    let store: ModelsPageStore
    let baseURL: URL
    @State private var copied: ModelConnectApp?
    @State private var installed: Set<ModelAgentSetup> = []
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use with a coding app").font(.headline)
            ForEach(ModelAgentSetup.allCases) { agent in agentRow(agent) }
            Text("Set Up writes one file that Noodle owns. Your own settings for the agent are not changed, and Remove deletes the file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: Space.s) {
                // Claude Code and Codex are set up above; these two take their settings by hand.
                ForEach([ModelConnectApp.cursor, .continueDev]) { app in
                    Button(copied == app ? String(localized: "Copied") : app.rawValue, systemImage: copied == app ? "checkmark" : "doc.on.doc") {
                        Task {
                            guard let key = await store.connectionKey() else { return }
                            let model = MLXServeLaunch.modelID(store.status.model ?? "local")
                            copyToPasteboard(app.snippet(baseURL: baseURL, key: key, model: model), concealed: true)
                            copied = app
                        }
                    }
                    .buttonStyle(.neutralAction).disabled(store.busy)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(copied == app ? "\(app.rawValue) setup copied" : "Copy \(app.rawValue) setup")
                }
            }
            Text("Copies a short setup with this server’s address and key.").font(.caption).foregroundStyle(.secondary)
        }
        .cardSurface()
        // A set-up agent follows the model that is loaded; opening the page also picks up a rotated key.
        .task(id: store.status.model) {
            installed = Set(ModelAgentSetup.allCases.filter { $0.isInstalled() })
            guard !installed.isEmpty, let model = store.status.model, let key = await store.serverKey() else { return }
            for agent in ModelAgentSetup.allCases where installed.contains(agent) && agent.isInstalled() {
                do { try agent.install(baseURL: baseURL, key: key, model: MLXServeLaunch.modelID(model)) } catch {
                    problem = error.localizedDescription
                }
            }
        }
        .alert("Couldn’t change the setup", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
        .onChange(of: store.status.model) { copied = nil }
        .onChange(of: store.status.phase) { copied = nil }
        .autoReset($copied, to: nil, after: .seconds(2))
    }

    @ViewBuilder private func agentRow(_ agent: ModelAgentSetup) -> some View {
        let file = agent.file()
        HStack(spacing: Space.s) {
            Text(agent.rawValue).font(.callout.weight(.medium)).frame(width: 96, alignment: .leading)
            if installed.contains(agent) {
                InlineCommand(command: agent.command(file: file)).frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(agent.command(file: file)) }
                    .buttonStyle(.neutralAction).accessibilityLabel("Copy the command that starts \(agent.rawValue) on Noodle")
                Button("Remove") {
                    do { try agent.remove(); installed.remove(agent) } catch { problem = error.localizedDescription }
                }
                .buttonStyle(.neutralAction).accessibilityLabel("Remove the \(agent.rawValue) setup")
            } else {
                Text(ModelAgentSetup.shellPath(file)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button("Set Up") { setUp(agent) }
                    .buttonStyle(.neutralAction).disabled(store.busy || store.demo || store.status.model == nil)
                    .accessibilityLabel("Set up \(agent.rawValue) to use this server")
            }
        }
        .motion(Motion.snappy, value: installed)
    }

    private func setUp(_ agent: ModelAgentSetup) {
        Task {
            guard let model = store.status.model, let key = await store.serverKey() else {
                problem = String(localized: "Noodle could not read the server key. Check that the model is still running.")
                return
            }
            do {
                try agent.install(baseURL: baseURL, key: key, model: MLXServeLaunch.modelID(model))
                installed.insert(agent)
            } catch { problem = error.localizedDescription }
        }
    }
}
