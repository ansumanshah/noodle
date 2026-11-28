import NoodleCore
import SwiftUI

struct ModelWorkspaceHeader: View {
    let store: ModelsPageStore
    let selected: LocalModel?
    let select: (String) -> Void
    /// Narrow windows keep the whole control cluster reachable: the status drops the backend and model name
    /// (the picker already names the model) and the picker caps its width, instead of the toolbar overflowing.
    var compact = false

    private var starting: Bool {
        if case .command(.start) = store.activity { return true }
        return store.status.phase == .starting
    }
    private var running: Bool { store.status.phase == .ready }
    private var stopping: Bool { store.activity == .command(.stop) }
    private var label: String { stopping ? "Stopping" : starting ? "Starting…" : running ? "Ready" : "Stopped" }
    private var activeModelName: String? {
        guard let id = store.status.model else { return nil }
        return store.models.first(where: { $0.id == id })?.name ?? id
    }
    private var selectionHelp: String {
        guard running, selected?.id != store.status.model, let activeModelName else {
            return "Choose a model, then start it explicitly"
        }
        return selected?.installed == true
            ? "The server is still running \(activeModelName). Stop it, then start the selected model."
            : "The server is still running \(activeModelName). Stop it, install the selected model from Library, then start it."
    }

    /// Inline layout, for hosts without a window toolbar (render tests, previews). The app puts the same two
    /// pieces in the window toolbar through `ModelsToolbar`, so no empty toolbar band sits above the page.
    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            titleBlock
            Spacer(minLength: Space.s)
            controls
        }
        .controlSize(.regular)
        .padding(.horizontal, Space.page).padding(.top, Space.panel).padding(.bottom, Space.m)
    }

    var titleBlock: some View {
        // The sidebar already names the page; the toolbar shows only what the server is doing.
        statusLine.fixedSize()
    }

    /// The window toolbar keeps only the model choice. Status and Start/Stop live on the sidebar card.
    var toolbarPicker: some View { modelPicker.fixedSize() }

    var controls: some View {
        HStack(spacing: Control.gap) {
            modelPicker
            ModelServerControl(store: store, selected: selected)
                .motion(Motion.snappy, value: running || starting || stopping)
            Button("Refresh Models", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .labelStyle(.iconOnly).buttonStyle(.iconAction)
                .help("Refresh models and server status")
                .disabled(store.busy)
        }
        .fixedSize()
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            ModelStatusDot(color: running ? Status.running : starting || stopping ? Status.warning : Color.secondary.opacity(0.6),
                           pulsing: starting || stopping)
            Text(label).foregroundStyle(running ? AnyShapeStyle(Status.running) : AnyShapeStyle(.secondary))
                .fontWeight(.medium)
                .contentTransition(.opacity)
            if let backend = store.status.backend, running, !compact {
                Text("·").foregroundStyle(.tertiary)
                Text(backend.displayName).foregroundStyle(.secondary)
            }
            if running, !compact, let activeModelName {
                Text("·").foregroundStyle(.tertiary)
                Text(activeModelName).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("Running model: \(activeModelName) (\(store.status.model ?? ""))")
                    .accessibilityLabel("Running model: \(activeModelName)")
            }
        }
        .font(.caption)
        .lineLimit(1)
        .motion(Motion.snappy, value: label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server status: \(label)")
    }

    private var modelPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            SearchablePicker(title: String(localized: "Selected model"),
                             options: store.chatModels.isEmpty ? [PickerOption(id: "", label: String(localized: "No models"))]
                                 : store.chatModels.map { PickerOption(id: $0.id, label: $0.name + ($0.installed ? "" : " · Not installed")) },
                             selection: Binding(get: { selected?.id ?? "" }, set: { select($0) }))
            .buttonStyle(.borderless).hoverFill()
            .frame(maxWidth: compact ? 140 : nil)
            .fixedSize(horizontal: !compact, vertical: true)
            // The picker's own title is its accessibility label; a second label made VoiceOver say it twice.
            .accessibilityIdentifier("models-selected-model")
        }
        .padding(.leading, Space.m).padding(.trailing, Space.s)
        .controlSurface()
        .disabled(store.busy)
        .help(selectionHelp)
    }
}

/// Chat's page controls, in the window toolbar: assistant, chat settings and New Chat.
struct ModelChatToolbarControls: View {
    let store: ModelsPageStore
    var compact = false

    var body: some View {
        HStack(spacing: Space.s) {
            ModelAssistantMenu(store: store, manage: { store.showsAssistants = true }, selectModel: { store.selectedModelID = $0 },
                           compact: compact)
            ModelChatSettingsButton(store: store)
            Button { store.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                .labelStyle(.iconOnly).buttonStyle(.iconAction)
                .disabled(store.busy)
                .help("Start a new conversation")
                .accessibilityIdentifier("models-new-chat")
        }
        .fixedSize()
    }
}
