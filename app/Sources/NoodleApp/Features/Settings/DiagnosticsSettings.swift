import AppKit
import NoodleCore
import SwiftUI

struct DiagnosticsSettings: View {
    let env: AppEnvironment
    @State private var component: LogComponent = .engine
    @State private var lines: [String] = []
    @State private var query = ""
    @State private var revision = 0
    @State private var exporting = false
    @State private var exportNote: String?
    @State private var showUninstall = false

    private var filtered: [String] {
        query.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var componentTitle: String {
        switch component {
        case .engine: "Engine"
        case .linux: "Linux VM"
        case .privileged: "Privileged containers VM"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MenuPicker(title: "Log", value: componentTitle, selection: $component) {
                    Text("Engine").tag(LogComponent.engine)
                    Text("Linux VM").tag(LogComponent.linux)
                    Text("Privileged containers VM").tag(LogComponent.privileged)
                }
                SearchField(prompt: String(localized: "Find in logs"), text: $query)
                Button("Refresh", systemImage: "arrow.clockwise") { revision += 1 }.buttonStyle(.neutralAction)
            }
            Text("\(filtered.count) of \(lines.count) recent lines").font(.callout).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(filtered.isEmpty ? (query.isEmpty ? "No log entries." : "No matching entries.") : filtered.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Saves logs, settings and versions with secrets removed. Nothing is uploaded.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                Button("Save Report…") { exportReport() }.disabled(exporting || env.demo)
            }
            if let exportNote { Text(exportNote).font(.callout).textSelection(.enabled) }
            Button("Uninstall Noodle…", role: .destructive) { showUninstall = true }
                .buttonStyle(ControlButtonStyle(tint: Status.stopped))
                .disabled(env.demo || env.macMachine.isActive || !env.nav.canChangeInstallation || env.nav.showSetup)
        }
        .padding(Space.xl)
        .sheet(isPresented: $showUninstall) { UninstallNoodleSheet(env: env) }
        .task(id: "\(component.rawValue)-\(revision)") {
            let url = component.file(in: env.paths)
            let result = await Task.detached {
                let redactor = Redactor()
                return DiagnosticLogs.tail(url, count: 200).map { redactor.redact($0) }
            }.value
            if !Task.isCancelled { lines = result }
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Noodle Diagnostics.tar.gz"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exporting = true
            exportNote = nil
            Task {
                let result = await CLI.run(["diagnostics", "--output", destination.path], timeout: 60)
                exporting = false
                exportNote = result.code == 0 ? "Report saved as \(destination.lastPathComponent)." :
                    DockerSettingsCommands.message(result, fallback: "Could not save the diagnostics report.")
            }
        }
    }
}
