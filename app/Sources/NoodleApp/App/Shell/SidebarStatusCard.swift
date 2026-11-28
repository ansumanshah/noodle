import SwiftUI

/// The status card under the sidebar rows. It follows the selected product (`SidebarRuntime`).
struct VMStatusPager: View {
    let env: AppEnvironment
    var compact = false
    @State private var chosen: MachinePlatform?

    private var viewingMac: Bool { env.nav.route == .machines && env.nav.machinePlatform == .macOS }
    private var hasMac: Bool { env.macMachine.files != nil || env.macMachine.isActive || viewingMac }

    private var firstPage: MachinePlatform {
        guard hasMac else { return .linux }
        let linuxRunning = env.connection.isUp && env.connection.vmReadiness?.state == "running"
        let macRunning = env.macMachine.machine != nil && env.macMachine.operation != .starting
        if linuxRunning != macRunning { return macRunning ? .macOS : .linux }
        return viewingMac ? .macOS : .linux
    }

    var body: some View {
        let first = firstPage
        let page = hasMac ? (chosen ?? first) : .linux
        let next: MachinePlatform = page == .linux ? .macOS : .linux
        let nextTitle = next == .linux ? "Linux VM" : "macOS VM"

        VStack(spacing: 6) {
            if env.connection.needsSetup, ![.models, .runners].contains(env.sidebarRuntime) {
                Button("Set Up Noodle…") { env.nav.requestSetup() }
                    .buttonStyle(ControlButtonStyle(fill: true))
                    .disabled(!env.nav.canChangeInstallation)
            }
            switch env.sidebarRuntime {
            case .linuxMachine: LinuxMachineStatusCard(env: env, compact: compact)
            case .macMachine: MacVMStatusCard(store: env.macMachine, env: env, compact: compact)
            case .kubernetes: KubernetesStatusCard(env: env, compact: compact)
            case .models: ModelServerStatusCard(env: env, compact: compact)
            case .runners: RunnersStatusCard(env: env, compact: compact)
            case .engine:
                if page == .macOS {
                    MacVMStatusCard(store: env.macMachine, env: env, compact: compact)
                } else {
                    LinuxVMStatusCard(connection: env.connection, env: env, compact: compact) { env.nav.showDockerDefault = true }
                }
            }
            if hasMac, env.sidebarRuntime == .engine {
                HStack(spacing: 4) {
                    Circle().fill(page == first ? .secondary : .quaternary).frame(width: 5, height: 5)
                    Circle().fill(page != first ? .secondary : .quaternary).frame(width: 5, height: 5)
                    Spacer()
                    Button { chosen = next } label: {
                        HStack(spacing: 4) {
                            Text(nextTitle)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(nextTitle)")
                    .help("Show \(nextTitle)")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, Space.xxs)
            }
        }
        // Flat on the sidebar: the navigation above is the card, so this part spends no inset of its own.
        .padding(.horizontal, Space.m).padding(.top, Space.s)
        .frame(maxWidth: .infinity)
        .onChange(of: first) { chosen = nil }
        .motion(Motion.snappy, value: page)
        .motion(Motion.snappy, value: env.sidebarRuntime)
        .motion(Motion.snappy, value: env.connection.needsSetup)
    }
}

private struct LinuxVMStatusCard: View {
    let connection: ConnectionModel
    let env: AppEnvironment
    var compact = false
    let useNoodle: () -> Void

    private var status: VMReadiness? { connection.vmReadiness }
    private var usage: VMReadiness.Usage? {
        guard connection.isUp, connection.transition == nil, status?.state == "running" else { return nil }
        return status?.usage
    }
    private var statusText: String { connection.vmStateText }
    private var cpuText: String {
        guard let count = usage?.cpus ?? status?.cpus ?? connection.info?.ncpu, count > 0 else { return "—" }
        if usage != nil, let percent = connection.vmCPUPercent { return "\(percent)% · \(count) vCPU" }
        return "\(count) vCPU"
    }
    private var limit: Int? {
        if let bytes = status?.memoryLimitBytes { return bytes }
        if let fallback = connection.info?.memTotal, fallback > 0 { return fallback }
        return nil
    }
    private var memoryText: String {
        guard let limit else { return "—" }
        // No usage sample yet (just booted, older daemon, demo): show the limit alone rather than "— / 4 GB".
        guard let used = usage?.memoryUsed.flatMap({ Int(exactly: $0) }) else { return Fmt.bytes(limit) }
        return Fmt.bytes(used) + " / " + Fmt.bytes(limit)
    }

    private var configuredText: String {
        let settings = connection.vmSettings
        let bytes = min(settings.memoryMiB, Int.max >> 20) << 20
        return "\(settings.cpus) vCPU · \(Fmt.bytes(bytes))"
    }

    var body: some View {
        let c = connection
        RuntimeCard(title: String(localized: "Linux VM"), status: statusText, running: connection.vmRunningNow) {
            if compact {
                EmptyView()
            } else if connection.vmRunningNow {
                RuntimeCardRow("CPU", cpuText)
                RuntimeCardRow("Memory", memoryText).help("Estimated guest working memory and its configured limit")
                if let used = usage?.memoryUsed, let limit {
                    ProgressView(value: min(Double(used) / Double(limit), 1))
                        .controlSize(.small).accessibilityLabel("VM memory usage")
                }
            } else {
                RuntimeCardRow("Configured", configuredText)
                    .help("CPU and memory configured for the next Linux VM start.")
            }
            RuntimeCardRow("Docker CLI", connection.dockerTarget ?? "—")
                .help("Target from Docker’s saved context and this app’s environment. A shell can override it.")
            if !connection.needsSetup {
                Button(c.isUp ? "Stop" : "Start", systemImage: c.isUp ? "stop.fill" : "play.fill") {
                    guard !env.demo else { return }
                    Task { c.isUp ? await env.stopDaemon() : await env.startDaemon() }
                }
                .buttonStyle(ControlButtonStyle(tint: c.isUp ? Status.stopped : Status.running, fill: true))
                .disabled(c.transition != nil || c.retryingConnection)
                .help(c.isUp ? "Stop the containers engine" : "Start the containers engine")
            }
            if connection.isUp, connection.dockerElsewhere {
                Button("Use Noodle for docker…", action: useNoodle)
                    .buttonStyle(ControlButtonStyle(tint: .primary, fill: true))
                    .help(connection.noodleContextMissing
                          ? "Docker has no noodle context yet, so docker --context noodle fails. Add it, or make Noodle the default."
                          : "Plain docker commands go to another engine. See what changes before you switch.")
                    .transition(.opacity)
            }
        } footer: {
            RuntimeCardFooter(env: env)
        }
    }
}

private struct MacVMStatusCard: View {
    let store: MacMachineStore
    let env: AppEnvironment
    var compact = false

    var body: some View {
        RuntimeCard(title: String(localized: "macOS VM"), status: store.statusText, running: store.isRunning) {
            if compact {
                EmptyView()
            } else if store.machine != nil, store.operation != .starting {
                RuntimeCardRow("CPU", store.usage?.cpuText ?? "—")
                    .help("Apple VM worker CPU. 100% equals one host core.")
                RuntimeCardRow("Host memory", store.usage?.memoryText ?? "—")
                    .help("Physical memory charged to the Apple VM worker, including its overhead.")
            } else if let profile = store.profile {
                RuntimeCardRow("Configured", "\(profile.cpus) vCPU · \(Fmt.bytes(Int(clamping: profile.memory)))")
            }
        } footer: {
            RuntimeCardFooter(env: env)
        }
    }
}
