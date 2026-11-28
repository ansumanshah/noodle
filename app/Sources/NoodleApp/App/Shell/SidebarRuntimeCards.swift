import NoodleCore
import SwiftUI

/// Sidebar cards for the runtimes behind Machines, Kubernetes and Models. Each supplies its own rows, read from the
/// store the matching page already uses, in the shared card layout.
struct LinuxMachineStatusCard: View {
    let env: AppEnvironment
    var compact = false

    var body: some View {
        let store = env.machines
        if let machine = env.sidebarMachine {
            RuntimeCard(title: String(localized: "Linux machine"), status: store.pending[machine.name] ?? machine.state.capitalized,
                   running: store.pending[machine.name] == nil && machine.isRunning) {
                RuntimeCardRow("Name", machine.name)
                if !compact {
                    RuntimeCardRow("Distribution", machine.distro.capitalized)
                    RuntimeCardRow("Resources", "\(machine.cpus) vCPU · \(Fmt.bytes(machine.memoryMiB << 20))")
                    if let address = store.info[machine.name]?.address { RuntimeCardRow("Address", address) }
                }
            } footer: { RuntimeCardFooter(env: env) }
        } else {
            RuntimeCard(title: String(localized: "Linux machine"), status: store.loaded ? String(localized: "None") : String(localized: "Loading"), running: false) {
                RuntimeCardRow("Machines", store.loaded ? "None yet" : "—")
            } footer: { RuntimeCardFooter(env: env) }
        }
    }
}

struct KubernetesStatusCard: View {
    let env: AppEnvironment
    var compact = false

    var body: some View {
        let store = env.kubernetes
        let snapshot = store.snapshot
        RuntimeCard(title: String(localized: "Kubernetes"), status: store.action != nil ? String(localized: "Working") : snapshot?.state ?? String(localized: "Checking"),
                running: store.action == nil && snapshot?.running == true) {
            if let snapshot, snapshot.exists {
                if !snapshot.version.isEmpty { RuntimeCardRow("Version", snapshot.version) }
                if snapshot.apiPort > 0 { RuntimeCardRow("API port", String(snapshot.apiPort)) }
                if !compact, snapshot.running { RuntimeCardRow("Pods", String(snapshot.pods.count)) }
            } else {
                RuntimeCardRow("Cluster", snapshot == nil ? "Checking" : "Not enabled")
            }
        } footer: { RuntimeCardFooter(env: env) }
    }
}

struct ModelServerStatusCard: View {
    let env: AppEnvironment
    var compact = false

    var body: some View {
        let store = env.modelsStore
        let status = store.status
        let busy = store.activity == .command(.stop) || status.phase == .starting
        let running = status.phase == .ready
        let model = status.model.flatMap { id in store.models.first { $0.id == id }?.name ?? id }
        RuntimeCard(title: String(localized: "Model server"), status: status.label(busy: busy), running: running) {
            RuntimeCardRow("Model", model ?? store.selectedModel?.name ?? "None")
            if let restarts = status.restarts, restarts > 0 {
                RuntimeCardRow("Restarts", "\(restarts)").help(status.lastCrash ?? "")
            }
            if !compact, running, let backend = status.backend { RuntimeCardRow("Backend", backend.displayName) }
            if running, let url = status.namedBaseURL ?? status.baseURL, let host = url.host {
                RuntimeCardRow("Endpoint", host + (url.port.map { ":\($0)" } ?? ""))
                    .help(url.absoluteString)
            }
            ModelServerControl(store: store, selected: store.selectedModel, fill: true)
        } footer: { RuntimeCardFooter(env: env) }
    }
}

extension LocalModelStatus {
    /// Plain status word; a stop that followed a crash says so, with the log tail in the card's Restarts row.
    func label(busy: Bool) -> String {
        if phase == .ready { return String(localized: "Ready") }
        if busy { return String(localized: "Starting…") }
        return lastCrash == nil ? String(localized: "Stopped") : String(localized: "Stopped after a problem")
    }
}

struct RunnersStatusCard: View {
    let env: AppEnvironment
    var compact = false

    var body: some View {
        let list = env.runnerRepos
        let status = RunnerRows.cardStatus(list.state, on: list.on)
        RuntimeCard(title: String(localized: "Runners"), status: status.text, running: status.healthy) {
            RuntimeCardRow("Repos", "\(list.items.count)")
            if !compact { RuntimeCardRow("Jobs running", "\(list.jobs)") }
            Button(list.on ? "Stop" : "Start", systemImage: list.on ? "stop.fill" : "play.fill") {
                // Demo pages keep the button live-looking for captures but never change runner state.
                guard !env.demo else { return }
                Task { _ = await list.setOn(!list.on, env: env) }
            }
            .buttonStyle(ControlButtonStyle(tint: list.on ? Status.stopped : Status.running, fill: true))
            .disabled(list.busy)
            .help(list.on ? "Stop running GitHub jobs on this Mac" : "Run GitHub jobs on this Mac")
        } footer: { RuntimeCardFooter(env: env) }
    }
}
