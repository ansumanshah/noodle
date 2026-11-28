import SwiftUI

/// Compose projects in their own section: the list, and the selected project's detail beside it.
struct ComposePage: View {
    let env: AppEnvironment

    private var projects: [ComposeProjectInfo] { ComposeProjects.group(env.containers.items) }

    var body: some View {
        @Bindable var nav = env.nav
        let query = env.nav.search.trimmingCharacters(in: .whitespaces)
        let all = projects
        let shown = all.filter { ListFilter.matches(query, $0.name, $0.directory) }
        let selected = all.first { $0.id == nav.selectedProject }
        VStack(spacing: 0) {
            ZStack {
                if case .down(let message) = env.connection.phase, !env.containers.loaded {
                    DaemonDownView(env: env, message: message).transition(.opacity)
                } else if !env.containers.loaded {
                    LoadingState(label: String(localized: "Loading…")).transition(.opacity)
                } else if all.isEmpty {
                    EmptyState(symbol: "square.stack.3d.down.right", title: String(localized: "No Compose projects"),
                               message: String(localized: "Run docker compose up in a project folder. It appears here as soon as it starts."),
                               command: "docker compose up -d")
                } else if shown.isEmpty {
                    EmptyState.search(query)
                } else {
                    HStack(spacing: 0) {
                        list(shown, selection: $nav.selectedProject)
                        if let selected {
                            Divider()
                            ComposeDetail(env: env, project: selected) { nav.selectedProject = nil }
                                .id(selected.id)
                                .frame(width: 340).frame(maxHeight: .infinity)
                                .background(WorkspaceStyle.content)
                                .transition(.slide(from: .trailing))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let e = env.compose.error { ErrorBanner(message: e) { env.compose.error = nil } }
            }
        }
        .pageSummary(String(localized: "\(Fmt.count(all.count, "project")), \(all.filter { $0.runningCount > 0 }.count) running"))
        .motion(Motion.standard, value: nav.selectedProject)
        .motion(Motion.standard, value: env.containers.loaded)
        .motion(Motion.snappy, value: env.compose.error)
        .task { try? await env.containers.refresh() }
    }

    private func list(_ shown: [ComposeProjectInfo], selection: Binding<String?>) -> some View {
        List(selection: selection) {
            ForEach(shown) { project in
                ComposeRow(project: project, progress: env.compose.progress[project.name])
                    .tag(project.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
        }
        .listStyle(.inset)
        .standardRows()
        .compactScrollbars()
        .scrollContentBackground(.hidden)
        .background(WorkspaceStyle.content)
        .motion(Motion.snappy, value: shown)
        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComposeRow: View {
    let project: ComposeProjectInfo
    let progress: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(project.name).lineLimit(1).layoutPriority(1)
            Text(folder).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let progress {
                ProgressView().controlSize(.small)
                Text(progress).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(project.runningCount)/\(project.containers.count) running")
                .font(.callout.monospacedDigit())
                .foregroundStyle(project.runningCount > 0 ? Status.running : .secondary)
                .fixedSize()
        }
        .frame(minHeight: RowSize.height)
    }

    private var folder: String {
        project.directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Folder unknown")
    }
}
