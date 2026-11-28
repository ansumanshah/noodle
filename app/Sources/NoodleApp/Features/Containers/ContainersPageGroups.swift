import SwiftUI

struct GroupHeader: View {
    let env: AppEnvironment
    let group: ContainerGroup
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false
    /// Keyboard focus on any project button shows them all, so a focused button is never invisible.
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(AIAppsStore.title(forProject: group.project)).font(.subheadline.weight(.semibold))
                    Text("\(group.runningCount) of \(group.containers.count) running")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .help(collapsed ? "Show containers" : "Hide containers")
            Spacer()
            if let project = group.project {
                let busy = group.containers.contains { env.containers.pending[$0.id] != nil }
                // Same 17-point columns and 8-point gaps as ContainerRow's actions, so header and row icons line up.
                HStack(spacing: ActionSlots.gap) {
                    // Restart and delete wait for the pointer; start and stop show whenever they apply, at the edge.
                    Group {
                        Button("Restart Project \(project)", systemImage: "arrow.clockwise") {
                            Task { await env.containers.perform(.restart, project: project) }
                        }
                        .help("Restart project \(project)").frame(width: ActionSlots.icon)
                        Button("Delete Project \(project)", systemImage: "trash") {
                            ContainerActions.confirmRemoveProject(env: env, project: project)
                        }
                        .help("Delete project \(project)").frame(width: ActionSlots.icon)
                    }
                    .foregroundStyle(.secondary)
                    .opacity(hovering || focused ? 1 : 0).allowsHitTesting(hovering || focused)
                    if group.runningCount < group.containers.count {
                        Button("Start Project \(project)", systemImage: "play.fill") {
                            Task { await env.containers.perform(.start, project: project) }
                        }
                        .foregroundStyle(Status.running)
                        .help("Start project \(project)").frame(width: ActionSlots.icon)
                    }
                    if group.runningCount > 0 {
                        Button("Stop Project \(project)", systemImage: "stop.fill") {
                            Task { await env.containers.perform(.stop, project: project) }
                        }
                        .foregroundStyle(Status.stopped)
                        .help("Stop project \(project)").frame(width: ActionSlots.icon)
                    }
                }
                .focused($focused)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless).hoverFill().controlSize(.regular)
                .disabled(busy)
                .motion(Motion.snappy, value: hovering)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .foregroundStyle(.primary)
        .padding(.vertical, Space.xxs)
        .contextMenu {
            if let project = group.project {
                projectActions(project)
                    .disabled(group.containers.contains { env.containers.pending[$0.id] != nil })
            }
        }
    }

    @ViewBuilder private func projectActions(_ project: String) -> some View {
        Button("Start Project", systemImage: "play.fill") { Task { await env.containers.perform(.start, project: project) } }
        Button("Stop Project", systemImage: "stop.fill") { Task { await env.containers.perform(.stop, project: project) } }
        Button("Restart Project", systemImage: "arrow.clockwise") { Task { await env.containers.perform(.restart, project: project) } }
        Divider()
        Button("Delete Project…", systemImage: "trash", role: .destructive) { ContainerActions.confirmRemoveProject(env: env, project: project) }
    }
}
