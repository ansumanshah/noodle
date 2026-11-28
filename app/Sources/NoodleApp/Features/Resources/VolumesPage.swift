import SwiftUI

struct VolumesPage: View {
    let env: AppEnvironment
    @State private var selection: Set<String> = []
    @State private var narrow = false

    var body: some View {
        @Bindable var model = env.volumes
        let q = env.nav.search.trimmingCharacters(in: .whitespaces)
        let rows = visibleRows
        ResourceShell(env: env, loaded: model.loaded, isEmpty: model.items.isEmpty, search: q, noMatches: rows.isEmpty,
                      empty: ResourceEmpty(symbol: "externaldrive", title: "No volumes yet",
                                           message: "Volumes keep data between container runs. Compose creates them for you, or make one yourself.",
                                           command: "docker volume create data"),
                      summary: Fmt.count(model.items.count, "volume"), error: $model.actionError) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { v in Text(v.name).lineLimit(1) }.width(min: 160, ideal: 240)
                TableColumn("Driver") { v in Text(v.driver).foregroundStyle(.secondary) }.width(80)
                if !narrow {
                    TableColumn("Location") { v in Text(v.mountpoint).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            .resourceRows(selection: $selection, narrow: $narrow, confirm: confirm)
            .pageActions([PageAction(id: "delete", title: "Delete", symbol: "trash", disabled: selection.isEmpty) { confirm(Array(selection)) }])
        }
        .onChange(of: q) { selection.formIntersection(visibleRows.map(\.id)) }
    }
    private var visibleRows: [VolumeSummary] { env.volumes.items.filter { ListFilter.matches(env.nav.search, $0.name) } }
    private func confirm(_ all: [String]) {
        env.confirmDelete(all, visible: visibleRows.map(\.id), selection: $selection,
                          title: { $0.count == 1 ? String(localized: "Delete volume “\($0[0])”?") : String(localized: "Delete \($0.count) volumes?") },
                          message: String(localized: "The data inside is permanently removed.")) { await env.volumes.remove($0) }
    }
}
