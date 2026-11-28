import NoodleCore
import SwiftUI

/// Start or Stop for the model server. Shared by the sidebar card and the inline header used in previews and render tests.
/// Start is green, Stop is red.
struct ModelServerControl: View {
    let store: ModelsPageStore
    let selected: LocalModel?
    var fill = false

    private var starting: Bool {
        if case .command(.start) = store.activity { return true }
        return store.status.phase == .starting
    }
    private var running: Bool { store.status.phase == .ready }
    private var stopping: Bool { store.activity == .command(.stop) }
    private var activeModelName: String? {
        guard let id = store.status.model else { return nil }
        return store.models.first(where: { $0.id == id })?.name ?? id
    }

    var body: some View {
        if running || starting || stopping {
            Button("Stop", systemImage: "stop.fill") { Task { await store.perform(.stop) } }
                .buttonStyle(ControlButtonStyle(tint: Status.stopped, fill: fill))
                .disabled(store.busy)
                .accessibilityIdentifier("models-server-stop")
                .help("Stop \(activeModelName ?? "the running model")")
        } else {
            Button("Start", systemImage: "play.fill") {
                if let selected { Task { await store.perform(.start(selected.id)) } }
            }
            .buttonStyle(ControlButtonStyle(tint: Status.running, fill: fill))
            .disabled(store.busy || selected?.installed != true)
            .accessibilityIdentifier("models-server-start")
            .help(selected?.installed == true ? "Start \(selected?.name ?? "the model")" : "Install the selected model from Library first")
        }
    }
}
