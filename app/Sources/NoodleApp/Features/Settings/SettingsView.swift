import SwiftUI
import AppKit
import NoodleCore

struct SettingsView: View {
    let env: AppEnvironment
    /// Tab tags. A page that sends people to Settings sets `selectionKey` first, so the window opens on the tab it means.
    static let selectionKey = "settingsTab"
    static let dockerTab = "docker"
    @AppStorage(SettingsView.selectionKey) private var tab = "resources"
    var body: some View {
        TabView(selection: $tab) {
            ResourcesSettings(env: env).tabItem { Label("Resources", systemImage: "cpu") }.tag("resources")
            SharingSettings(env: env).tabItem { Label("File Sharing", systemImage: "folder") }.tag("sharing")
            DockerSettings(env: env).tabItem { Label("Docker", systemImage: "shippingbox") }.tag("docker")
            SettingsNetworkSections(env: env).tabItem { Label("Network", systemImage: "network") }.tag("network")
            ModelSettings(env: env).tabItem { Label("Models", systemImage: "cube") }.tag("models")
            ImportSettings(env: env).tabItem { Label("Import", systemImage: "square.and.arrow.down") }.tag("import")
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "textformat.size") }.tag("appearance")
            DiagnosticsSettings(env: env).tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag("diagnostics")
            UpdatesSettings(env: env).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
        }
        .tint(WorkspaceStyle.accent)
        .buttonStyle(.neutralAction)
        .frame(minWidth: 710, idealWidth: 710, minHeight: 480, idealHeight: 480)
        .compactScrollbars()
    }
}

struct ResourcesSettings: View {
    let env: AppEnvironment
    @State private var settings = VMSettings.defaults()
    @State private var saved = VMSettings.defaults()
    @State private var note: String?
    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let hostMiB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.cpus, in: 1...hostCPUs) { LabeledContent("CPUs", value: "\(settings.cpus)") }
                LabeledContent("Memory") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(value: Binding(get: { Double(settings.memoryMiB) }, set: { settings.memoryMiB = Int($0 / 256) * 256 }),
                               in: 512...Double(max(1024, hostMiB / 2)), step: 256).frame(width: 220)
                        Text(Fmt.bytes(settings.memoryMiB * 1_048_576)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Stepper(value: $settings.diskGiB, in: 1...max(1024, saved.diskGiB)) {
                    LabeledContent("New data disk", value: "\(settings.diskGiB) GiB")
                }
            } header: {
                Text("Linux VM")
            } footer: {
                Text("CPU and memory changes apply the next time the VM starts.")
                Text("Disk size is used only when Noodle creates a new data disk. An existing disk keeps its size.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Revert") { settings = saved }.disabled(settings == saved)
                    Button("Save") { save(restart: false) }.disabled(settings == saved || env.demo)
                    Button("Save and Restart") { save(restart: true) }.disabled(settings == saved || env.demo)
                }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
        .onAppear { let s = env.demo ? VMSettings.defaults() : VMSettings.load(paths: env.paths); settings = s; saved = s }
    }

    private func save(restart: Bool) {
        guard !env.demo else { return }
        do {
            // vm.json may have changed while the form was open (`noodle share`, a hand-edited "host_loopback").
            settings = settings.keepingFileManagedValues(from: VMSettings.load(paths: env.paths))
            try settings.save(paths: env.paths)
            env.reloadVMSettings()
            saved = settings
            note = restart ? "Restarting Noodle…" : "Saved. Applies the next time the VM starts."
            if restart {
                Task {
                    await env.stopDaemon()
                    if let error = env.connection.message {
                        note = "Saved, but Noodle could not stop: \(error)"
                    } else if (try? await env.service.ping()) != nil {
                        note = "Saved, but Noodle is still running."
                    } else {
                        await env.startDaemon()
                        if let error = env.connection.message {
                            note = "Saved, but Noodle could not start: \(error)"
                        } else if (try? await env.service.ping()) != nil {
                            note = "Noodle restarted. New limits apply when the VM starts."
                        } else {
                            note = "Saved, but Noodle did not start."
                        }
                    }
                }
            }
        } catch { note = error.localizedDescription }
    }
}

struct AppearanceSettings: View {
    @AppStorage("terminalTheme") private var terminalTheme = "github"
    @AppStorage("logFontSize") private var size = 12.0
    @AppStorage("logTimestamps") private var times = true
    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Theme", selection: $terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                CommandBlock(command: "docker --context noodle ps")
            }
            Section {
                LabeledContent("Font size") {
                    HStack { Slider(value: $size, in: 10...18, step: 1).frame(width: 180); Text("\(Int(size)) pt").monospacedDigit().frame(width: 44, alignment: .trailing) }
                }
                Toggle("Show timestamps", isOn: $times)
            } header: { Text("Container logs") }
            QuickAskSection()
        }
        .formStyle(.grouped)
    }
}

