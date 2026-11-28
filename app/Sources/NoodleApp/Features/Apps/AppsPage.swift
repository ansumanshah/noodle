import AppKit
import SwiftUI

/// One-click apps: a grid of cards, details on the side. Plain words, no container terms.
struct AppsPage: View {
    let env: AppEnvironment
    @State private var selectedID: String?

    private var store: AIAppsStore { env.apps }
    private var selected: AIApp? { store.catalog.first { $0.id == selectedID } }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ZStack {
                if case .down(let message) = env.connection.phase, !env.containers.loaded {
                    DaemonDownView(env: env, message: message).transition(.opacity)
                } else if !env.containers.loaded {
                    LoadingState(label: String(localized: "Loading…")).transition(.opacity)
                } else {
                    content.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { if let e = store.error { ErrorBanner(message: e) { store.error = nil } } }
        }
        .pageSummary(summary)
        .motion(Motion.standard, value: env.containers.loaded)
        .removeDialogs(store: store)
        .task { try? await env.containers.refresh() }
    }

    private var summary: String {
        let running = store.catalog.filter { store.state($0) == .running }.count
        return String(localized: "\(store.catalog.count) apps, \(running) running. Each runs on your Mac and can use your local model.")
    }

    /// Under this width the detail floats over the grid instead of taking a column, so the cards never get squeezed.
    private static let overlayBelow: CGFloat = 760
    @State private var width: CGFloat = 1000

    private var content: some View {
        let overlay = width < Self.overlayBelow
        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: Space.m, alignment: .top)], spacing: Space.m) {
                        ForEach(store.catalog) { app in
                            AppCard(app: app, store: store, selected: selectedID == app.id) { selectedID = app.id }
                        }
                    }
                    .padding(Space.page)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                if let app = selected, !overlay { detail(app, width: 320) }
            }
            if let app = selected, overlay {
                detail(app, width: min(320, width - Space.page))
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .motion(Motion.standard, value: selectedID)
    }

    private func detail(_ app: AIApp, width: CGFloat) -> some View {
        AppDetail(app: app, store: store) { selectedID = nil }
            .frame(width: width)
            .paneCard()
            .padding(.vertical, Space.s).padding(.trailing, Space.s)
            .transition(.slide(from: .trailing))
    }
}

private struct AppCard: View {
    let app: AIApp
    let store: AIAppsStore
    let selected: Bool
    let select: () -> Void
    @Environment(\.productTone) private var tone

    var body: some View {
        let state = store.state(app)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Image(systemName: app.symbol)
                    .font(.title3.weight(.medium)).foregroundStyle(tone.ink)
                    .frame(width: Tile.size, height: Tile.size)
                    .background(tone.soft, in: .rect(cornerRadius: Radius.panel, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text(statusText(state)).font(.caption).foregroundStyle(state == .running ? Status.running : .secondary)
                }
                Spacer(minLength: 0)
            }
            Text(app.summary).font(.callout).foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
            // The tag shrinks to its icon before it can wrap, so the button never loses room.
            ViewThatFits(in: .horizontal) {
                footer(compactTag: false)
                footer(compactTag: true)
            }
        }
        .padding(Space.panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(selected ? 0.14 : 0.07), in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.primary.opacity(selected ? 0.2 : 0.06)) }
        .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture(perform: select)
        .focusable().focusEffectDisabled()
        .onKeyPress(keys: [.return, .space]) { _ in select(); return .handled }
        .contextMenu { AppActions(app: app, store: store) }
        .motion(Motion.snappy, value: selected)
        // Combined like selectableRow: VoiceOver reads name, status and summary; the primary button becomes an action.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Select"), select)
    }

    private func footer(compactTag: Bool) -> some View {
        HStack {
            if app.usesModel { ModelTag(compact: compactTag) }
            Spacer(minLength: 0)
            AppPrimaryButton(app: app, store: store)
        }
    }

    private func statusText(_ state: AIAppState) -> String {
        if let progress = store.progress[app.id] { return progress }
        switch state {
        case .notInstalled: return app.category
        case .running: return String(localized: "Running")
        case .stopped: return String(localized: "Stopped")
        }
    }
}

struct ModelTag: View {
    var compact = false
    var body: some View {
        Label("Uses your local model", systemImage: "cpu")
            .labelStyle(CompactLabelStyle(compact: compact)).lineLimit(1).fixedSize()
            .help("Uses your local model")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Get when it is not installed, Open when it runs, Start when it is stopped. Start is green.
struct AppPrimaryButton: View {
    let app: AIApp
    let store: AIAppsStore

    var body: some View {
        let busy = store.busy(app)
        switch store.state(app) {
        case .notInstalled:
            Button("Get") { Task { await store.install(app) } }.buttonStyle(.primaryAction).disabled(busy)
        case .running:
            Button("Open") { NSWorkspace.shared.open(store.url(app)) }.buttonStyle(.primaryAction).disabled(busy)
        case .stopped:
            Button("Start") { Task { await store.start(app) } }.buttonStyle(ControlButtonStyle(tint: Status.running)).disabled(busy)
        }
    }
}

/// Secondary actions, shared by the card's context menu and the detail pane.
struct AppActions: View {
    let app: AIApp
    let store: AIAppsStore

    var body: some View {
        let state = store.state(app)
        if state == .running { Button("Stop") { Task { await store.stop(app) } } }
        if state.isInstalled {
            Button("Update") { Task { await store.install(app, update: true) } }
            Button("Remove…") { store.confirmRemove = app }
        }
    }
}

private extension View {
    /// Remove asks twice: remove the app, then keep or delete its data.
    func removeDialogs(store: AIAppsStore) -> some View {
        @Bindable var store = store
        return confirmationDialog(
            String(localized: "Remove \(store.confirmRemove?.name ?? "")?"),
            isPresented: $store.confirmRemove.isPresent(),
            titleVisibility: .visible, presenting: store.confirmRemove
        ) { app in
            Button("Remove", role: .destructive) { store.confirmRemove = nil; store.askDeleteData = app }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The app stops and disappears from this list.") }
        .confirmationDialog(
            String(localized: "Delete \(store.askDeleteData?.name ?? "")’s data too?"),
            isPresented: $store.askDeleteData.isPresent(),
            titleVisibility: .visible, presenting: store.askDeleteData
        ) { app in
            Button("Keep my data") { Task { await store.remove(app, deleteData: false) } }
            Button("Delete data", role: .destructive) { Task { await store.remove(app, deleteData: true) } }
        } message: { _ in Text("Keep it and your chats and files are back if you get the app again. Deleting cannot be undone.") }
    }
}

private struct CompactLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { Label(configuration) }
    }
}
