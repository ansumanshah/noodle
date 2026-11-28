import SwiftUI

struct ContainerListView: View {
    let env: AppEnvironment
    @Binding var statusFilter: ContainerStatusFilter
    let open: (String) -> Void
    @State private var collapsed: Set<String> = []
    /// Row inset inside the inset list, so row text lines up with card content on other pages (page + panel).
    private static let inset: CGFloat = 21

    var body: some View {
        @Bindable var nav = env.nav
        let query = nav.search.trimmingCharacters(in: .whitespaces)
        let projectGroups = env.containers.groups.filter { nav.selectedProject == nil || $0.project == nav.selectedProject }
        let groups = filtered(projectGroups, query: query)
        let imageSizes = Dictionary(env.images.items.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            if groups.isEmpty && !query.isEmpty {
                EmptyState.search(query)
            } else if groups.isEmpty && statusFilter != .all {
                EmptyState(symbol: "line.3.horizontal.decrease.circle", title: statusFilter.emptyTitle,
                           message: "", secondary: (String(localized: "Show All"), { statusFilter = .all }), compact: true)
            } else if groups.isEmpty {
                if nav.selectedProject == nil {
                    EmptyState(symbol: "shippingbox", title: String(localized: "No containers"),
                               message: String(localized: "Run one from your terminal, or start a Compose project. It appears here as soon as it starts."),
                               command: RunCommand.command(elsewhere: env.connection.dockerElsewhere || env.connection.noodleContextMissing),
                               secondary: (String(localized: "Browse Images"), { nav.route = .images }))
                } else {
                    EmptyState(symbol: "shippingbox", title: String(localized: "No containers in this project"),
                               message: String(localized: "Containers in this project appear here once Compose creates them."))
                }
            } else {
                List(selection: $nav.selectedContainers) {
                    ForEach(groups) { group in
                        // The header is the section's first row, not a pinned header, so no hairline draws under it.
                        Section {
                            GroupHeader(env: env, group: env.containers.groups.first { $0.id == group.id } ?? group,
                                        collapsed: collapsed.contains(group.id)) {
                                Motion.animate(Motion.standard) {
                                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: Self.inset, bottom: 0, trailing: Self.inset - Space.s))
                            if !collapsed.contains(group.id) {
                                ForEach(group.containers) { c in
                                    ContainerRow(env: env, container: c, pending: env.containers.pending[c.id],
                                                 imageSize: imageSizes[c.imageID])
                                        .tag(c.id)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 0, leading: Self.inset, bottom: 0, trailing: Self.inset))
                                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .listSectionSeparator(.hidden)
                .standardRows()
                .compactScrollbars()
                .scrollContentBackground(.hidden)
                .background(WorkspaceStyle.content)
                .motion(Motion.standard, value: collapsed)
                .motion(Motion.snappy, value: groups)
                .contextMenu(forSelectionType: String.self) { ids in
                    ContainerMenu(env: env, ids: Array(ids))
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { open(id) }
                }
                .onDeleteCommand { ContainerActions.confirmRemove(env: env, ids: Array(env.nav.selectedContainers)) }
            }
        }
        .onChange(of: statusFilter) { nav.selectedContainers.formIntersection(groups.flatMap { $0.containers.map(\.id) }) }
        .onChange(of: query) { nav.selectedContainers.formIntersection(groups.flatMap { $0.containers.map(\.id) }) }
    }

    private func filtered(_ groups: [ContainerGroup], query: String) -> [ContainerGroup] {
        return groups.compactMap { g in
            let hit = g.containers.filter {
                statusFilter.matches($0) && ListFilter.matches(query, $0.name, $0.image, $0.project)
            }
            return hit.isEmpty ? nil : ContainerGroup(project: g.project, containers: hit)
        }
    }
}
