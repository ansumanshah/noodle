import SwiftUI

/// Which runtime the sidebar card describes. It follows the selected sidebar item, so the card always shows the state of
/// the thing the page beside it is about. Every value is read from a store that already exists.
enum SidebarRuntime: Equatable {
    case engine, linuxMachine, macMachine, kubernetes, models, runners

    static func forRoute(_ route: Route, platform: MachinePlatform) -> SidebarRuntime {
        switch route {
        case .machines: platform == .macOS ? .macMachine : .linuxMachine
        case .kubernetes: .kubernetes
        case .chat, .create, .library, .apps, .connections: .models
        case .runners, .runnerRepos, .runnerJobs, .runnerCaches: .runners
        default: .engine
        }
    }
}

extension AppEnvironment {
    var sidebarRuntime: SidebarRuntime { .forRoute(nav.route, platform: nav.machinePlatform) }

    /// The machine the card shows: the one selected on the Machines page, else the first running one, else the first.
    var sidebarMachine: LinuxMachine? {
        machines.items.first { $0.id == nav.selectedMachine } ?? machines.items.first(where: \.isRunning) ?? machines.items.first
    }

    var modelsStore: ModelsPageStore { ModelsPage.sharedStore(demo: demo) }

    /// What the toolbar status dot shows while the sidebar is hidden: the same runtime the card would.
    var runtimeSummary: RuntimeStatus {
        switch sidebarRuntime {
        case .engine:
            return engineStatus
        case .linuxMachine:
            guard let machine = sidebarMachine else { return (String(localized: "Linux machine · none"), false, false) }
            let pending = machines.pending[machine.name]
            return (String(localized: "Linux machine \(machine.name) · \(pending ?? machine.state.capitalized)"), machine.isRunning, pending != nil)
        case .macMachine:
            return (String(localized: "macOS VM · \(macMachine.statusText)"), macMachine.machine != nil && !macMachine.shutdownRequested,
                    macMachine.operation != nil)
        case .kubernetes:
            let snapshot = kubernetes.snapshot
            return (String(localized: "Kubernetes · \(kubernetes.action != nil ? String(localized: "Working") : snapshot?.state ?? String(localized: "Checking"))"),
                    snapshot?.running == true, kubernetes.action != nil)
        case .models:
            let store = modelsStore
            let busy = store.activity == .command(.stop) || store.status.phase == .starting
            let running = store.status.phase == .ready
            return (busy ? String(localized: "Server starting…") : running ? String(localized: "Server running") : String(localized: "Server stopped"), running, busy)
        case .runners:
            let list = runnerRepos
            return (list.on ? String(localized: "Runners on") : String(localized: "Runners off"), list.on, list.busy)
        }
    }
}

/// One status line (text, dot, spinner) shared by the sidebar card footer and the toolbar dot.
typealias RuntimeStatus = (text: String, running: Bool, busy: Bool)

extension AppEnvironment {
    var engineStatus: RuntimeStatus { (connection.engineStatusText, connection.isUp, connection.engineBusy) }
}
