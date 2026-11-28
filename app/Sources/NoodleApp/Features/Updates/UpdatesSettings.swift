import SwiftUI
import NoodleCore

struct UpdatesSettings: View {
    let env: AppEnvironment
    @State private var updater = Updater.shared
    @State private var confirmingRestart = false
    @State private var checking = false
    @State private var warning = ""

    var body: some View {
        Form {
            if let error = updater.restartError {
                Text(error).foregroundStyle(Status.error).textSelection(.enabled)
            }
            Section {
                LabeledContent("Version", value: updater.currentVersion)
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small).transition(.opacity) }
                        Text(statusText).foregroundStyle(failed ? Status.error : Color.secondary)
                            .contentTransition(.opacity).id(statusText)
                            .transition(.opacity)
                    }
                    .motion(Motion.snappy, value: updater.status)
                }
                HStack {
                    Spacer()
                    Button("Check Now") {
                        guard !env.demo else { return }
                        Task { await updater.check(manual: true) }
                    }
                        .disabled(env.demo || busy || checking || updater.status == .unavailable)
                    if case .ready = updater.status {
                        Button("Restart to Update") { restart() }
                            .buttonStyle(.primaryAction)
                            .disabled(env.demo || checking)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .motion(Motion.snappy, value: updater.status)
            } header: { Text("Noodle updates") }
              footer: { Text("Updates are signed by the developer and checked before they are installed. Nothing installs until you choose Restart to Update.") }
            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automatic }, set: {
                    guard !env.demo else { return }
                    updater.automatic = $0
                }))
                    .disabled(env.demo || updater.status == .unavailable)
            } footer: { Text("Checks every six hours while the Noodle window is open and downloads a verified update in the background. When off, only Check Now contacts the update server.") }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restart to update?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Stop Containers and Update", role: .destructive) { install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(warning)
        }
    }

    /// Ask the daemon now (a cached count can be a minute old). Containers running, or no answer: ask first.
    private func restart() {
        guard !env.demo else { return }
        checking = true
        Task {
            let count = await updater.runningContainers(env: env)
            checking = false
            if let message = UpdateInstallWarning.message(running: count) {
                warning = message
                confirmingRestart = true
            } else { install() }
        }
    }
    private func install() {
        guard !env.demo else { return }
        Task { await updater.installAndRestart(env: env) }
    }

    private var busy: Bool {
        switch updater.status { case .checking, .downloading, .installing: true; default: false }
    }
    private var failed: Bool { if case .failed = updater.status { true } else { false } }
    private var statusText: String {
        switch updater.status {
        case .idle: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "Noodle is up to date"
        case .downloading(let v): "Downloading \(v)…"
        case .ready(let v): "Version \(v) is ready to install"
        case .installing: "Installing…"
        case .failed(let m): m
        case .unavailable: "Updates are off in this build"
        }
    }
}
