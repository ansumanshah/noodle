import SwiftUI

struct InfoTab: View {
    let env: AppEnvironment
    let container: ContainerSummary
    @State private var details: ContainerDetails?
    @State private var failure: String?
    @State private var showEnv = false
    @State private var stats: StatsSample?

    var body: some View {
        Form {
            Section("Container") {
                LabeledContent("Image", value: container.image)
                LabeledContent("ID") { Text(container.id).font(.callout.monospaced()).textSelection(.enabled) }
            }
            if container.isRunning, let stats {
                Section("Resource snapshot") {
                    LabeledContent("CPU", value: Fmt.percent(stats.cpuPercent))
                    LabeledContent("Memory", value: "\(Fmt.bytes(stats.memoryBytes)) / \(Fmt.bytes(stats.memoryLimit))")
                    LabeledContent("Network", value: "\(Fmt.bytes(stats.netRx)) in · \(Fmt.bytes(stats.netTx)) out")
                    LabeledContent("Processes", value: String(stats.pids))
                }
            }
            Section("Ports") {
                if container.publishedPorts.isEmpty && container.ports.isEmpty {
                    Text("No ports published").foregroundStyle(.secondary)
                } else {
                    ForEach(container.ports.sorted { ($0.publicPort ?? 0, $0.privatePort) < ($1.publicPort ?? 0, $1.privatePort) }) { p in
                        PortRow(port: p, live: container.state == "running",
                                name: p.id == container.openablePorts.first?.id ? env.containers.names.link(for: container) : nil)
                    }
                }
            }
            if let d = details {
                Section("Overview") {
                    LabeledContent("Status", value: container.status)
                    if !d.command.isEmpty {
                        LabeledContent("Command") { Text(d.command).font(.body.monospaced()).textSelection(.enabled) }
                    }
                    if let w = d.config?.workingDir, !w.isEmpty { LabeledContent("Working directory") { Text(w).font(.body.monospaced()).textSelection(.enabled) } }
                    if let u = d.config?.user, !u.isEmpty { LabeledContent("User", value: u) }
                    LabeledContent("Created", value: Fmt.ago(container.created))
                    if container.isRunning, let pid = d.state?.pid, pid > 0 { LabeledContent("PID", value: String(pid)) }
                    if !container.isRunning, let code = d.state?.exitCode { LabeledContent("Exit code", value: String(code)) }
                }
                if let nets = d.networkSettings?.networks, !nets.isEmpty {
                    Section("Networks") {
                        ForEach(nets.keys.sorted(), id: \.self) { name in
                            if let address = nets[name]?.ipAddress, !address.isEmpty {
                                LabeledContent(name) { Text(address).font(.body.monospaced()).textSelection(.enabled) }
                            } else {
                                Text(name)
                            }
                        }
                    }
                }
                if let mounts = d.mounts, !mounts.isEmpty {
                    Section("Mounts") {
                        ForEach(mounts) { m in
                            LabeledContent {
                                HStack {
                                    Text(m.destination ?? "").font(.body.monospaced()).textSelection(.enabled)
                                    if let folder = m.hostFolder {
                                        Button("Show in Finder", systemImage: "folder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                                        }.labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().help("Show \(folder.path) in Finder")
                                    }
                                }
                            } label: {
                                Text(m.name ?? m.source ?? "").lineLimit(1).truncationMode(.middle)
                                Text((m.type ?? "").capitalized + (m.rw == false ? " · read-only" : "")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let envs = d.config?.env, !envs.isEmpty {
                    Section {
                        Toggle("Environment (\(envs.count))", isOn: $showEnv).toggleStyle(.button)
                        if showEnv {
                            ForEach(envs, id: \.self) { e in
                                Text(e).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } else if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Status.warning) }
            } else {
                Section { HStack { ProgressView().controlSize(.regular); Text("Loading details…").foregroundStyle(.secondary) } }
            }
        }
        .formStyle(.grouped)
        .task(id: container.state) {
            do { details = try await env.service.inspect(container.id); failure = nil }
            catch { failure = error.localizedDescription }
        }
        .task(id: container.state) {
            stats = nil
            if container.isRunning { stats = try? await env.service.statsSnapshot(container.id) }
        }
    }
}

struct PortRow: View {
    let port: PortMapping
    var live = true
    /// The container's local name, shown in place of `localhost:port` on its first openable port.
    var name: (host: String, url: URL)?
    var body: some View {
        LabeledContent {
            if live, let url = name?.url ?? port.url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(name?.host ?? "localhost:\(port.publicPort ?? 0)", systemImage: "arrow.up.forward.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                .help("Open \(url.absoluteString)")
            } else {
                Text(port.publicPort == nil ? "not published" : "localhost:\(port.publicPort ?? 0)").foregroundStyle(.tertiary)
            }
        } label: {
            Text(verbatim: "\(port.privatePort)/\(port.type)").font(.body.monospaced())
        }
    }
}
