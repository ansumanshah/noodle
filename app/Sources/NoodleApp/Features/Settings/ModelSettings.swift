import AppKit
import NoodleCore
import SwiftUI

/// Where models install. The CLI saves the choice and tells a running model server to rescan.
struct ModelSettings: View {
    let env: AppEnvironment
    @State private var folder = ""
    @State private var custom = false
    @State private var missing = false
    @State private var busy = false
    @State private var note: String?
    @State private var keepAlive = "5m"
    @State private var network = false
    @State private var networkURL: String?
    @State private var networkIP: String?
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(folder).textSelection(.enabled).truncationMode(.middle).lineLimit(1)
                }
                if missing {
                    Label("This folder is not available. Connect its drive or choose another folder.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change…") { choose() }
                    Button("Use Default") { Task { await apply(["--reset"]) } }.disabled(!custom)
                }
                .disabled(env.demo || busy)
            } header: {
                Text("Model location")
            } footer: {
                Text("New downloads and imports go to this folder, which can be on an external drive. Models already installed stay in their old folder.")
            }
            Section {
                Picker("Keep a model loaded for", selection: $keepAlive) {
                    ForEach(ModelKeepAliveSetting.presets, id: \.duration) { Text($0.title).tag($0.duration) }
                }
                .onChange(of: keepAlive) { _, value in
                    // load() sets the picker too; only a real change is saved.
                    guard value != (ModelKeepAliveSetting.savedText(root: env.paths.root) ?? "5m") else { return }
                    Task { await run(["model", "keep-alive", value]) }
                }
                Button("Unload Now") { Task { await run(["model", "stop"]) } }
            } header: {
                Text("Memory")
            } footer: {
                Text("A model that has not been used for this long is unloaded to free memory, and the next request loads it again. A change applies the next time a model starts; a model that is running keeps its current setting until you unload it.")
            }
            .disabled(env.demo || busy)
            Section {
                Toggle("Allow other devices to use my models", isOn: $network)
                    .onChange(of: network) { _, value in
                        guard value != ModelNetworkSetting.enabled(root: env.paths.root) else { return }
                        Task { await run(["model", "network", value ? "on" : "off"], timeout: 240); await loadNetwork() }
                    }
                if network {
                    copyRow("Address", networkURL ?? "Not on a network")
                    if let networkIP { copyRow("Or by IP address", networkIP) }
                    copyRow("Key", apiKey, secret: true)
                    Button("New Key") { Task { await run(["model", "key", "--rotate"], timeout: 240); await loadNetwork() } }
                }
            } header: {
                Text("Network")
            } footer: {
                Text(network ? "Other devices on your network can chat with and use the models on this Mac with this key. Their prompts run on this Mac. Turn this off or make a new key to cut access. A new key restarts a running model."
                             : "Off: only this Mac can use your models.")
            }
            .disabled(env.demo || busy)
            if let note { Text(note).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func copyRow(_ title: LocalizedStringKey, _ value: String, secret: Bool = false) -> some View {
        LabeledContent(title) {
            HStack {
                Text(secret ? String(repeating: "•", count: 12) : value).textSelection(.enabled).truncationMode(.middle).lineLimit(1)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().help("Copy")
            }
        }
    }

    private func loadNetwork() async {
        network = ModelNetworkSetting.enabled(root: env.paths.root)
        guard network else { return }
        let info = await CLI.run(["model", "network", "--json"], timeout: 10)
        if let data = info.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            networkURL = json["url"] as? String
            networkIP = json["ipURL"] as? String
        }
        apiKey = await CLI.run(["model", "key"], timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        Task { await loadNetwork() }
        folder = ModelLocation.weights(root: env.paths.root).path
        custom = ModelLocation.custom(root: env.paths.root) != nil
        keepAlive = ModelKeepAliveSetting.savedText(root: env.paths.root) ?? "5m"
        missing = ModelLocation.unavailable(root: env.paths.root) != nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await apply([url.path]) }
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 60) async {
        busy = true
        defer { busy = false }
        let result = await CLI.run(arguments, timeout: timeout)
        note = result.code == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply(_ arguments: [String]) async {
        busy = true
        defer { busy = false }
        let result = await CLI.run(["model", "location"] + arguments, timeout: 30)
        note = result.code == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        load()
    }
}
