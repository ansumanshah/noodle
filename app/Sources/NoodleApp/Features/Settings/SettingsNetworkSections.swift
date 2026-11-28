import SwiftUI
import AppKit

struct SettingsNetworkSections: View {
    let env: AppEnvironment
    @State private var store = SettingsNetworkStore()

    var body: some View {
        Form {
            localNames
            publicLinks
            finder
            proxy
            Section {
                HStack {
                    Button("Refresh") { Task { await store.refresh(env: env) } }
                    if store.busy { ProgressView().controlSize(.small) }
                }
                if env.demo { Text("Preview only. Network settings are unchanged.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .disabled(store.busy || env.demo)
        .task { await store.refresh(env: env) }
    }

    private var localNames: some View {
        Section {
            CommandBlock(command: "noodle names")
        } header: {
            Text("Local names")
        } footer: {
            Text("A running container with a web port gets a name ending in .localhost, over HTTP and HTTPS. For HTTPS without a browser warning, run noodle names trust once.")
        }
    }

    private var publicLinks: some View {
        Section {
            if let note = store.linksNote {
                Text(note).foregroundStyle(.secondary)
            } else if store.links.isEmpty {
                Text("No public links. Create one with noodle link CONTAINER.").foregroundStyle(.secondary)
            }
            ForEach(store.links) { link in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: "\(link.containerName):\(link.containerPort)")
                        Spacer()
                        Text(link.state).foregroundStyle(.secondary)
                        Button("Stop", role: .destructive) {
                            Task { await store.stopLink(link.id, env: env) }
                        }.buttonStyle(ControlButtonStyle(tint: Status.stopped))
                    }
                    if let url = link.url {
                        HStack {
                            Text(url).textSelection(.enabled).font(.callout)
                            Spacer()
                            Button("Copy URL") {
                                copyToPasteboard(url)
                            }.accessibilityLabel("Copy public URL for \(link.containerName)")
                        }
                    }
                    if let detail = link.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Public links")
        } footer: {
            Text("Anyone with the link can connect, and Noodle adds no sign-in. Traffic passes through Cloudflare, which can read it, passwords included. The app behind a link keeps its mounted folders and network access.")
        }
    }

    private var finder: some View {
        Section {
            Toggle("Enable Finder view", isOn: Binding(
                get: { store.finder.url != nil },
                set: { enabled in Task { await store.setFinder(enabled: enabled, env: env) } }))
            LabeledContent("Status", value: store.finder.mounted ? "Mounted, read-only" : (store.finder.url == nil ? "Off" : "On, not mounted"))
            if let path = store.finder.mountpoint {
                Text(path).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button("Open in Finder") { openFinder() }
                    .disabled(!store.finder.mounted || store.finder.mountpoint == nil)
                if store.finder.url != nil && !store.finder.mounted {
                    Button("Mount") { Task { await store.setFinder(enabled: true, env: env) } }
                }
            }
            if let note = store.finderNote { Text(note).foregroundStyle(.secondary) }
        } header: {
            Text("Finder view")
        } footer: {
            Text("Browse container files and volumes through a read-only mount. Browsing a stopped container does not start it.")
        }
    }

    private var proxy: some View {
        Section {
            Picker("Mode", selection: $store.proxy.mode) {
                Text("System").tag("system")
                Text("Custom").tag("custom")
                Text("Off").tag("off")
            }
            if store.proxy.mode == "custom" {
                SecureField("HTTP proxy URL", text: Binding(
                    get: { store.proxy.url ?? "" },
                    set: { store.proxy.url = $0.isEmpty ? nil : $0 }))
                LabeledContent("HTTPS proxy", value: "Uses the same HTTP proxy URL")
                TextField("Skip proxy for (comma separated)", text: Binding(
                    get: { store.proxy.exceptions.joined(separator: ", ") },
                    set: { store.proxy.exceptions = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
            }
            Toggle("Pass proxy to new containers", isOn: $store.proxy.injectIntoContainers)
                .disabled(store.proxy.mode == "off")
            HStack {
                Button("Revert") { store.proxy = store.savedProxy }
                    .disabled(store.proxy == store.savedProxy)
                Button("Save") { Task { await store.saveProxy(env: env) } }
                    .disabled(!store.loaded || store.proxy == store.savedProxy)
                Button("Test Connection") { Task { await store.testProxy(env: env) } }
                    .disabled(!store.loaded || store.proxy != store.savedProxy)
            }
            if let note = store.proxyNote { Text(note).foregroundStyle(.secondary) }
        } header: {
            Text("Proxy")
        } footer: {
            Text("Used for image pulls and pushes. Custom takes one http:// proxy for both HTTP and HTTPS. The skip list takes hosts, domain suffixes and IPv4 ranges. Passing the proxy to containers affects new containers only, and is refused for a proxy with a password or one on loopback. Test Connection asks Docker Hub about one small image with the saved settings and downloads nothing.")
        }
        .disabled(!store.loaded)
    }

    private func openFinder() {
        guard !env.demo, ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] != "1",
              store.finder.mounted, let path = store.finder.mountpoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
