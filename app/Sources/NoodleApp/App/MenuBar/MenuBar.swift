import SwiftUI

struct MenuBarLabel: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let name = env.connection.isUp ? "MenuBarIcon" : "MenuBarIconOff"
        // The asset catalog exists only in the packaged app (make-app.sh); `swift run` falls back to a symbol.
        (NSImage(named: name) != nil ? Image(name) : Image(systemName: env.connection.isUp ? "shippingbox.fill" : "shippingbox"))
            .task { env.openMain = { openWindow(id: "main") } }
            .task { await MenuBarStore.shared.watchOpenings(env: env) }
    }
}

/// Native menu: state, projects, ports, machines, then the app actions. Data is read when the menu opens.
struct MenuBarContent: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let c = env.connection
        let summary = MenuBarSummary.make(containers: env.containers.items, machines: MenuBarStore.shared.machines, isUp: c.isUp, names: env.containers.names)
        Text(verbatim: String(localized: "Noodle · \(status(c))"))
        if c.isUp, c.transition == nil {
            let count = env.containers.runningCount
            Text(count == 1 ? "1 container running" : "\(count) containers running")
            if let vm = c.vmReadiness, vm.state == "running" {
                let stats = MenuBarSummary.vmStats(vm, cpuPercent: c.vmCPUPercent)
                if !stats.isEmpty { Text(verbatim: stats) }
            }
        }
        if !summary.items.isEmpty {
            Section("Projects") {
                ForEach(summary.items) { item in
                    Button { env.showMainWindow(item.destination) } label: {
                        if item.failed { Label { Text(item.title) } icon: { MenuDot.red } } else { Text(item.title) }
                    }
                    if let failure = item.failure {
                        Button { env.showMainWindow(.container(failure.containerID)) } label: {
                            Label { Text(failure.text) } icon: { MenuDot.red }
                        }
                    }
                }
                if summary.totalItems > summary.items.count { Button("Show All \(summary.totalItems)") { env.showMainWindow(.route(.containers)) } }
            }
        }
        if !summary.ports.isEmpty {
            Section("Ports") {
                ForEach(summary.ports) { port in
                    Button(port.title) { activate(port) }
                }
                if summary.totalPorts > summary.ports.count { Button("Show All \(summary.totalPorts)") { env.showMainWindow(.route(.containers)) } }
            }
        }
        if !summary.machines.isEmpty {
            Section("Machines") {
                ForEach(summary.machines) { machine in
                    Button(machine.title) { openShell(machine.name) }
                }
                if summary.totalMachines > summary.machines.count { Button("Show All \(summary.totalMachines)") { env.showMainWindow(.route(.machines)) } }
            }
        }
        Divider()
        Button("Open Noodle") { env.showMainWindow() }.keyboardShortcut("o").disabled(!env.nav.canChangeInstallation)
        if c.isUp {
            Button("Stop Noodle") { Task { await env.stopDaemon() } }.disabled(c.transition != nil)
        } else {
            Button("Start Noodle Containers") { Task { await env.startDaemon() } }.disabled(c.transition != nil || !env.nav.canChangeInstallation)
        }
        Divider()
        Button("Settings…") { NSApp.activate(); openSettings() }.keyboardShortcut(",")
        Button("Quit Noodle") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(env.nav.installationBusy)
    }

    private func status(_ c: ConnectionModel) -> String {
        if let t = c.transition { return t == .starting ? String(localized: "Starting…") : String(localized: "Stopping…") }
        switch c.phase {
        case .up: return String(localized: "Running")
        case .connecting: return String(localized: "Checking…")
        case .down: return String(localized: "Stopped")
        }
    }

    /// Web ports open in the browser. Database ports copy their address, since a browser cannot show them.
    private func activate(_ port: MenuBarSummary.Port) {
        if port.copies {
            copyToPasteboard(port.address)
        } else if let url = port.endpoint.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func openShell(_ name: String) {
        guard !env.demo else { return }
        do { try TerminalLauncher.open(machine: name) }
        catch { env.connection.message = error.localizedDescription }
    }
}

/// The Failed symbol, red, keeping its color in a native menu: a palette symbol is not a template image.
enum MenuDot {
    static var red: Image {
        let palette = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Failed"))?
            .withSymbolConfiguration(palette)
        return image.map(Image.init(nsImage:)) ?? Image(systemName: "xmark.circle.fill")
    }
}

struct NoodleCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Set Up Noodle…") { env.nav.requestSetup() }
                .disabled(!env.nav.canChangeInstallation || env.nav.showUninstall)
            Button("Uninstall Noodle…", role: .destructive) { env.nav.showUninstall = true }
                .disabled(env.demo || env.macMachine.isActive || !env.nav.canChangeInstallation || env.nav.showSetup)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Route.Mode.allCases) { mode in
                Button(mode.title) { Motion.animate(Motion.standard) { env.nav.switchMode(mode) } }
                    .keyboardShortcut(mode.shortcutKey, modifiers: .command)
            }
            Divider()
            ForEach(env.nav.mode.routes) { r in
                Button(r.title) { env.nav.open(.route(r)) }
            }
            Divider()
            Button("Refresh") { Task { await env.sync.refreshWorkspace() } }.keyboardShortcut("r")
        }
        CommandMenu("Container") {
            let ids = Array(env.nav.selectedContainers)
            let sel = ids.compactMap { env.containers.container($0) }
            Button("Start") { Task { await env.containers.perform(.start, ids: ids) } }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(sel.isEmpty || sel.allSatisfy(\.isRunning))
            Button("Stop") { Task { await env.containers.perform(.stop, ids: ids) } }
                .keyboardShortcut("x", modifiers: [.command, .shift]).disabled(!sel.contains(where: \.isRunning))
            Button("Restart") { Task { await env.containers.perform(.restart, ids: ids) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!sel.contains(where: \.isRunning))
            Divider()
            Button("Open in Terminal") { if let id = env.nav.focusedContainer { ContainerActions.openInTerminal(env: env, id: id) } }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(env.nav.focusedContainer == nil)
            Button("Open in Browser") { if let id = env.nav.focusedContainer { ContainerActions.openInBrowser(env: env, id: id) } }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(env.nav.focusedContainer.flatMap { env.containers.container($0) }?.openablePorts.isEmpty ?? true)
            Divider()
            ForEach(Array(ContainerTab.allCases.enumerated()), id: \.element) { i, t in
                Button("Show \(t.title)") {
                    if let id = env.nav.focusedContainer { env.nav.open(container: id) }
                    env.nav.route = .containers
                    env.nav.tab = t
                }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Delete…") { ContainerActions.confirmRemove(env: env, ids: ids) }
                .keyboardShortcut(.delete, modifiers: .command).disabled(sel.isEmpty)
        }
    }
}
