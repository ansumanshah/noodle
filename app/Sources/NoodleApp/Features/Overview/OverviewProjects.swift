import SwiftUI
import AppKit

/// Compose projects first, then lone containers as ordinary rows. A project with a failed member shows it inline.
struct ProjectsCard: View {
    let env: AppEnvironment
    /// Exit times the page has learned, so a project lists the same failures as the attention rows.
    let finished: [String: Date]
    private let cap = 5

    private enum Entry: Identifiable {
        case project(ContainerGroup, failed: [ContainerSummary])
        case container(ContainerSummary)
        var id: String {
            switch self { case .project(let g, _): "project:" + (g.project ?? ""); case .container(let c): c.id }
        }
    }

    private var entries: [Entry] {
        let failing = Set(OverviewProblems.failing(env.containers.items, finished: finished).map(\.id))
        var projects: [Entry] = [], loose: [Entry] = []
        for group in env.containers.groups {
            if group.project != nil {
                projects.append(.project(group, failed: group.containers.filter { failing.contains($0.id) }))
            } else {
                loose += group.containers.map { .container($0) }
            }
        }
        // Stable order: rows never swap places when a problem appears. The attention row already leads with trouble.
        return projects + loose
    }

    var body: some View {
        let all = entries
        OverviewCard(title: String(localized: "Projects")) {
            if all.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No projects or containers running. Start a container from your terminal to see it here:")
                        .font(.callout).foregroundStyle(.secondary)
                    RunCommand(elsewhere: env.connection.dockerElsewhere || env.connection.noodleContextMissing)
                    HStack(spacing: 8) {
                        Button("Browse Images", systemImage: "square.3.layers.3d") { env.nav.route = .images }
                            .buttonStyle(.neutralAction)
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 2)
            } else {
                OverviewRows(items: Array(all.prefix(cap))) { entry in
                    switch entry {
                    case .project(let group, let failed): OverviewProjectRow(env: env, group: group, failed: failed)
                    case .container(let c): OverviewContainerRow(env: env, c: c, finished: finished)
                    }
                }
                if all.count > cap {
                    Button("Show All \(all.count)") { env.nav.selectedProject = nil; env.nav.route = .containers }
                        .buttonStyle(.link)
                }
            }
        }
        .motion(Motion.standard, value: all.map(\.id))
    }
}

private struct OverviewProjectRow: View {
    let env: AppEnvironment
    let group: ContainerGroup
    let failed: [ContainerSummary]

    private var members: String { group.containers.map { $0.service ?? $0.name }.sorted().joined(separator: ", ") }

    var body: some View {
        let name = group.project ?? ""
        let running = group.containers.filter { $0.state == "running" }.count
        let active = group.runningCount > 0
        let busy = group.containers.contains { env.containers.pending[$0.id] != nil }
        let summary = "\(running) of \(group.containers.count) running" + (failed.isEmpty ? "" : ", \(failed.count) failed")
        OverviewRow(accessibilityLabel: name, value: summary + ". " + members, action: open) {
            HStack(alignment: .top, spacing: 12) {
                OverviewDot(color: failed.isEmpty ? (running > 0 ? Status.running : .gray) : Status.error).padding(.top, Space.xs)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    ProjectCount(running: running, total: group.containers.count, members: members)
                    ForEach(failed) { c in
                        HStack(spacing: 8) {
                            OverviewDot(color: Status.error, size: 7)
                            Text(c.service ?? c.name).font(.callout)
                            Text(OverviewProblems.word(c)).font(.callout).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                }
            }
        } trailing: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                if let member = failed.first ?? group.containers.first {
                    RowAction(title: String(localized: "Logs for \(member.service ?? member.name)"), symbol: "text.alignleft") { logs(member) }
                }
                if active {
                    RowAction(title: String(localized: "Stop"), symbol: "stop.fill", tint: Status.stopped) { Task { await env.containers.perform(.stop, project: name) } }
                    RowAction(title: String(localized: "Restart"), symbol: "arrow.clockwise") { Task { await env.containers.perform(.restart, project: name) } }
                } else {
                    RowAction(title: String(localized: "Start"), symbol: "play.fill", tint: Status.running) { Task { await env.containers.perform(.start, project: name) } }
                }
            }
            .disabled(busy)
        } menu: {
            Button("Open") { open() }
            ForEach(group.containers) { member in
                Button("Logs: \(member.service ?? member.name)") { logs(member) }
            }
            if active {
                Button("Stop") { Task { await env.containers.perform(.stop, project: name) } }
                Button("Restart") { Task { await env.containers.perform(.restart, project: name) } }
            } else {
                Button("Start") { Task { await env.containers.perform(.start, project: name) } }
            }
            Divider()
            Button("Copy Name") { copyToPasteboard(name) }
            Button("Delete Project…") { ContainerActions.confirmRemoveProject(env: env, project: name) }
        }
    }

    private func open() {
        env.nav.selectedContainers = []; env.nav.detailContainer = nil
        env.nav.selectedProject = group.project; env.nav.route = .containers
    }

    private func logs(_ member: ContainerSummary) {
        env.nav.open(container: member.id)
        env.nav.tab = .logs
    }
}

/// "3 of 4 running", with the member names after it while the row is hovered or has keyboard focus.
private struct ProjectCount: View {
    let running: Int
    let total: Int
    let members: String
    @Environment(\.overviewRowRevealed) private var revealed

    var body: some View {
        Text("\(running) of \(total) running" + (revealed ? " · " + members : ""))
            .font(.callout).foregroundStyle(.secondary).lineLimit(revealed ? nil : 1)
            .fixedSize(horizontal: false, vertical: true).help(members)
    }
}

private struct OverviewContainerRow: View {
    let env: AppEnvironment
    let c: ContainerSummary
    let finished: [String: Date]

    var body: some View {
        let busy = env.containers.pending[c.id] != nil
        OverviewRow(accessibilityLabel: c.name, value: c.status, action: { env.nav.open(container: c.id) }) {
            HStack(spacing: 12) {
                OverviewDot(color: OverviewDot.color(c, finished: finished))
                Text(c.name).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                HiddenWhileRevealed { Text(OverviewProblems.stateLabel(c)).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
        } trailing: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                if c.isRunning {
                    RowAction(title: String(localized: "Stop"), symbol: "stop.fill", tint: Status.stopped) { Task { await env.containers.perform(.stop, ids: [c.id]) } }
                } else {
                    RowAction(title: String(localized: "Start"), symbol: "play.fill", tint: Status.running) { Task { await env.containers.perform(.start, ids: [c.id]) } }
                }
            }
            .disabled(busy)
        } menu: {
            Button("Open") { env.nav.open(container: c.id) }
            Button(c.isRunning ? "Stop" : "Start") {
                Task { await env.containers.perform(c.isRunning ? .stop : .start, ids: [c.id]) }
            }
            if c.isRunning { Button("Restart") { Task { await env.containers.perform(.restart, ids: [c.id]) } } }
            Divider()
            Button("Copy Name") { copyToPasteboard(c.name) }
            Button("Copy ID") { copyToPasteboard(c.shortID) }
        }
    }
}
