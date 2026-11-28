import SwiftUI

struct ContainersPage: View {
    /// Both fit beside the widest sidebar at the minimum window (MinimumWindowLayoutTests); the detail grows to 420 pt.
    static let listMinWidth: CGFloat = 170
    static let detailMinWidth: CGFloat = 260
    let env: AppEnvironment
    @AppStorage("dockerElsewhereNoteDismissed") private var elsewhereDismissed = false
    @State private var statusFilter: ContainerStatusFilter = .all

    var body: some View {
        let c = env.connection
        ZStack {
            if case .down(let msg) = c.phase, !env.containers.loaded {
                DaemonDownView(env: env, message: msg)
                    .transition(.opacity)
            } else if env.containers.loaded, env.containers.items.isEmpty, c.needsSetup {
                EmptyState(symbol: "shippingbox", title: String(localized: "No containers"), message: "",
                           action: (String(localized: "Set Up Noodle…"), !env.nav.canChangeInstallation, { env.nav.requestSetup() }))
            } else if !env.containers.loaded {
                LoadingState(label: String(localized: "Connecting to Noodle…")).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: Self.listMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if let id = env.nav.detailContainer, let container = env.containers.container(id) {
                        // The selected container opens as a card from the right edge.
                        ContainerDetailView(env: env, container: container) {
                            env.nav.detailContainer = nil
                            env.nav.selectedContainers = []
                        }
                        .id(id)
                        .frame(minWidth: Self.detailMinWidth, idealWidth: 420, maxWidth: 420, maxHeight: .infinity)
                        .paneCard()
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                        .padding(.vertical, Space.s).padding(.trailing, Space.s)
                        .transition(.slide(from: .trailing))
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if case .down(let message) = c.phase {
                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Label("Connection lost", systemImage: "exclamationmark.triangle")
                                    .font(.callout.weight(.semibold))
                                Text("\(message) Showing the last loaded containers.")
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer(minLength: Space.xxs)
                            retryConnection
                        }
                        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
                        .background(WorkspaceStyle.sidebar)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let err = env.containers.actionError {
                ErrorBanner(message: err) { env.containers.actionError = nil }
            }
        }
        .onChange(of: env.nav.selectedContainers) { _, ids in
            if ids.count == 1, let id = ids.first, env.containers.container(id) != nil {
                env.nav.detailContainer = id
            } else {
                env.nav.detailContainer = nil
            }
        }
        .onChange(of: env.nav.tab) { _, _ in
            if env.nav.detailContainer == nil, let id = env.nav.focusedContainer { env.nav.detailContainer = id }
        }
        .motion(Motion.standard, value: env.nav.detailContainer)
        .motion(Motion.standard, value: env.containers.loaded)
        .motion(Motion.standard, value: env.containers.items.isEmpty)
        .motion(Motion.snappy, value: env.containers.actionError)
        .motion(Motion.snappy, value: env.connection.dockerElsewhere)
        .motion(Motion.snappy, value: elsewhereDismissed)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if env.connection.dockerElsewhere, !elsewhereDismissed, let target = env.connection.dockerTarget {
                DockerElsewhereNote(target: target) { env.nav.showDockerDefault = true } dismiss: { elsewhereDismissed = true }
                    .transition(.opacity)
                Divider()
            }
            ContainerListView(env: env, statusFilter: $statusFilter) { id in
                env.nav.tab = .info
                env.nav.selectedContainers = [id]
                env.nav.detailContainer = id
            }
        }
        .pageSummary(String(localized: "\(env.containers.runningCount) running · \(env.containers.items.count) total")) {
            FilterChips(items: ContainerStatusFilter.allCases, selection: $statusFilter, title: \.title)
        }
    }

    private var retryConnection: some View {
        Button(env.connection.retryingConnection ? "Reconnecting…" : "Retry Connection") {
            Task { await env.sync.retryConnection() }
        }
        .buttonStyle(.neutralAction)
        .disabled(env.connection.transition != nil || env.connection.retryingConnection)
    }
}

struct DaemonDownView: View {
    let env: AppEnvironment
    let message: String
    var body: some View {
        let c = env.connection
        let starting = c.transition == .starting
        let locked = !env.nav.canChangeInstallation
        EmptyState(symbol: "shippingbox", title: String(localized: "Start Noodle Containers"),
                   message: String(localized: "Run Docker containers, Compose and Kubernetes on this Mac."),
                   command: "docker run --rm alpine echo hello",
                   action: c.setupDone
                       ? (starting ? String(localized: "Starting…") : String(localized: "Start"),
                          c.transition != nil || c.retryingConnection || locked, { Task { await env.startDaemon() } })
                       : (String(localized: "Set Up Noodle…"), locked, { env.nav.requestSetup() }),
                   secondary: c.setupDone && c.needsSetup ? (String(localized: "Set Up Noodle…"), { env.nav.requestSetup() }) : nil,
                   hint: String(localized: "Starts in about a second. Nothing runs at login."))
            .help(message)
    }
}
