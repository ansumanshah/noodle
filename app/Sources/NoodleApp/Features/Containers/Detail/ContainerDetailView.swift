import SwiftUI

struct ContainerDetailView: View {
    let env: AppEnvironment
    let container: ContainerSummary
    let back: () -> Void

    var body: some View {
        @Bindable var nav = env.nav
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                switch nav.tab {
                case .info: InfoTab(env: env, container: container)
                case .logs: LogsTab(env: env, container: container)
                case .run: RunTab(env: env, container: container)
                case .files: FilesTab(env: env, container: container)
                case .stats: StatsTab(env: env, container: container)
                }
            }
            .id(nav.tab)
            .background(CompactScrollbars().id(nav.tab).frame(width: 0, height: 0))
            .transition(.opacity)
            .motion(Motion.standard, value: nav.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        @Bindable var nav = env.nav
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(container.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if !container.image.isEmpty {
                        Text(container.image).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Close Details", systemImage: "xmark", action: back)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().tint(.primary).help("Close details")
            }
            HStack(spacing: 8) {
                StatePill(state: container.state, pending: env.containers.pending[container.id])
                if let name = env.containers.names.link(for: container) {
                    Button { NSWorkspace.shared.open(name.url) } label: {
                        Label(String(name.host), systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.link).help("Open \(name.url.absoluteString)")
                } else if let port = container.openablePorts.first, let url = port.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label(String(":\(port.publicPort ?? 0)"), systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.link).help("Open \(url.absoluteString)")
                }
                Spacer(minLength: 0)
                Button("Open Shell", systemImage: "terminal") { ContainerActions.openInTerminal(env: env, id: container.id) }
                    .labelStyle(.iconOnly).disabled(!container.isRunning).help("Open shell")
            }
            ChipTabBar(tabs: ContainerTab.allCases, selection: $nav.tab, title: \.title, symbol: \.symbol, compact: true)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("View")
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { ContainerMenu(env: env, ids: [container.id]) }
    }
}
