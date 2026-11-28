import NoodleCore
import SwiftUI

struct ImportSettings: View {
    let env: AppEnvironment
    @State private var sources: [SetupEngine] = []
    @State private var chosenSource = ""
    @State private var kinds = Set(SetupImportKind.allCases)
    @State private var scanning = false
    @State private var task: Task<Void, Never>?
    @State private var message: String?

    private var source: SetupEngine? { sources.first { $0.name == chosenSource } }
    private var selectedKinds: [SetupImportKind] {
        guard let inventory = source?.inventory else { return [] }
        return SetupImportKind.allCases.filter { kinds.contains($0) && $0.count(in: inventory) > 0 }
    }

    var body: some View {
        Form {
            Section {
                if !sources.isEmpty {
                    Picker("Source engine", selection: $chosenSource) {
                        ForEach(sources) { source in Text(source.displayName).tag(source.name) }
                    }
                    .disabled(task != nil)
                    if let inventory = source?.inventory {
                        ForEach(SetupImportKind.allCases, id: \.self) { kind in
                            let count = kind.count(in: inventory)
                            if count > 0 {
                                Toggle("\(kind.title) (\(count))", isOn: Binding(
                                    get: { kinds.contains(kind) },
                                    set: { if $0 { kinds.insert(kind) } else { kinds.remove(kind) } }
                                ))
                                .toggleStyle(.checkbox)
                                .disabled(task != nil)
                            }
                        }
                    }
                } else if !scanning {
                    Text("No other running engine has images, volumes, or stopped containers to copy.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh Sources") { Task { await refresh() } }.disabled(scanning || task != nil)
                    Spacer()
                    if let task {
                        Button("Cancel Copy") { task.cancel() }
                    } else {
                        Button("Copy to Noodle") { copyItems() }.disabled(env.demo || scanning || selectedKinds.isEmpty)
                    }
                    if scanning || task != nil { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Import from another engine")
            } footer: {
                Text("Start the source engine first. Noodle copies the selected items and skips names that already exist. Source data stays in place.")
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: chosenSource) { kinds = Set(SetupImportKind.allCases) }
        .onDisappear { task?.cancel() }
    }

    private func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let backend: any SetupBackend = env.demo ? ScriptedSetupBackend() : LiveSetupBackend(env: env)
        let snapshot = await backend.detect()
        guard !Task.isCancelled else { return }
        let target = env.paths.socket.resolvingSymlinksInPath()
        sources = snapshot.importable.filter { URL(fileURLWithPath: $0.socket).resolvingSymlinksInPath() != target }
        if !sources.contains(where: { $0.name == chosenSource }) { chosenSource = sources.first?.name ?? "" }
    }

    private func copyItems() {
        let flags = selectedKinds.map(\.flag)
        guard let source, !flags.isEmpty, task == nil, !env.demo else { return }
        message = "Copying from \(source.displayName)…"
        task = Task {
            let result = await SetupImportInvocation.run("unix://" + source.socket, flags: flags)
            message = DockerSettingsCommands.message(result, fallback: result.code == 0 ? "Copy complete." : "Copy failed.")
            task = nil
            if result.code == 0 { await env.sync.refreshNow() }
        }
    }
}
