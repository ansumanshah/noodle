import AppKit
import SwiftUI

/// The side pane for one app: what it is, its address, and the actions that do not fit on the card.
struct AppDetail: View {
    let app: AIApp
    let store: AIAppsStore
    let close: () -> Void
    @Environment(\.productTone) private var tone

    var body: some View {
        let state = store.state(app)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top) {
                    Image(systemName: app.symbol).font(.largeTitle.weight(.medium)).foregroundStyle(tone.ink)
                        .frame(width: Tile.hero, height: Tile.hero)
                        .background(tone.soft, in: .rect(cornerRadius: Radius.card, style: .continuous))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                        .foregroundStyle(.secondary)
                }
                Text(app.name).font(.title2.weight(.semibold))
                if let progress = store.progress[app.id] {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(progress).font(.callout) }
                }
                Text(app.about).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if app.usesModel { ModelTag() }
                HStack(spacing: Space.s) {
                    AppPrimaryButton(app: app, store: store)
                    if state == .running {
                        Button("Stop") { Task { await store.stop(app) } }.buttonStyle(ControlButtonStyle(tint: Status.stopped))
                    }
                }
                .controlSize(.large).disabled(store.busy(app))
                if state.isInstalled {
                    Card(title: String(localized: "Address")) {
                        Text(store.url(app).absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    HStack {
                        Button("Update") { Task { await store.install(app, update: true) } }
                        Button("Remove…") { store.confirmRemove = app }
                    }
                    .buttonStyle(.neutralAction).disabled(store.busy(app))
                    Text("Your data is kept on this Mac until you delete it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Space.panel)
        }
        .background(Color.secondary.opacity(0.03))
    }
}
