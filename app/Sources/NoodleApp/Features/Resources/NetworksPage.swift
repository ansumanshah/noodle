import SwiftUI

struct NetworksPage: View {
    let env: AppEnvironment
    @State private var selection: Set<String> = []
    @State private var narrow = false

    var body: some View {
        @Bindable var model = env.networks
        let q = env.nav.search.trimmingCharacters(in: .whitespaces)
        let rows = visibleRows
        ResourceShell(env: env, loaded: model.loaded, isEmpty: model.items.isEmpty, search: q, noMatches: rows.isEmpty,
                      empty: ResourceEmpty(symbol: "network", title: "No networks",
                                           message: "Containers on the same network reach each other by name.",
                                           command: "docker network create app"),
                      summary: Fmt.count(model.items.count, "network"), error: $model.actionError) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { n in
                    HStack(spacing: 6) { Text(n.name); if n.isBuiltIn { Text("built-in").font(.subheadline).foregroundStyle(.secondary) } }
                }.width(min: 100, ideal: 200)
                TableColumn("Driver") { n in Text(n.driver).foregroundStyle(.secondary) }.width(80)
                if !narrow { TableColumn("Scope") { n in Text(n.scope).foregroundStyle(.secondary) }.width(70) }
                TableColumn("Subnet") { n in Text(n.subnet ?? "").font(.body.monospaced()).foregroundStyle(.secondary) }.width(min: 100, ideal: 140)
                TableColumn("Containers") { n in if n.attached > 0 { Text("\(n.attached)").monospacedDigit() } }.width(80)
            }
            .resourceRows(selection: $selection, narrow: $narrow,
                          deletable: { ids in Array(ids.filter { id in !(model.items.first { $0.id == id }?.isBuiltIn ?? true) }) },
                          confirm: confirm)
        }
        .onChange(of: q) { selection.formIntersection(visibleRows.map(\.id)) }
    }
    private var visibleRows: [NetworkSummary] { env.networks.items.filter { ListFilter.matches(env.nav.search, $0.name) } }
    private func confirm(_ all: [String]) {
        env.confirmDelete(all, visible: visibleRows.map(\.id), selection: $selection,
                          title: { $0.count == 1 ? String(localized: "Delete this network?") : String(localized: "Delete \($0.count) networks?") },
                          message: String(localized: "Networks with attached containers can’t be deleted.")) { await env.networks.remove($0) }
    }
}
