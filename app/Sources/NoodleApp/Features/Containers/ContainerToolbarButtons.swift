import SwiftUI

struct ContainerToolbarButtons: View {
    let env: AppEnvironment
    var body: some View {
        let ids = Array(env.nav.selectedContainers)
        let selected = ids.compactMap { env.containers.container($0) }
        let anyRunning = selected.contains(where: \.isRunning)
        let allRunning = !selected.isEmpty && selected.allSatisfy(\.isRunning)
        let busy = selected.contains { env.containers.pending[$0.id] != nil }
        Button(allRunning ? "Stop" : "Start", systemImage: allRunning ? "stop.fill" : "play.fill") {
            Task { await env.containers.perform(allRunning ? .stop : .start, ids: ids) }
        }
        .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(tint: allRunning ? Status.stopped : Status.running, square: true))
        .disabled(selected.isEmpty || busy)
        .help(allRunning ? "Stop (⇧⌘X)" : "Start (⇧⌘S)")
        Button("Restart", systemImage: "arrow.triangle.2.circlepath") { Task { await env.containers.perform(.restart, ids: ids) } }
            .labelStyle(.iconOnly).buttonStyle(.iconAction)
            .disabled(!anyRunning || busy)
            .help("Restart (⇧⌘R)")
        Button("Delete", systemImage: "trash") { ContainerActions.confirmRemove(env: env, ids: ids) }
            .labelStyle(.iconOnly).buttonStyle(.iconAction)
            .disabled(selected.isEmpty || busy)
            .help("Delete (⌘⌫)")
    }
}
