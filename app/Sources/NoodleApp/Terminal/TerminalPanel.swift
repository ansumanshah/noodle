import SwiftUI

struct TerminalPanel: View {
    let workspace: TerminalWorkspace
    @AppStorage("terminalTheme") private var theme = "github"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.productTone) private var tone

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let tab = workspace.selected {
                TerminalSplitView(tab: tab, layout: tab.layout, workspace: workspace)
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "terminal", title: String(localized: "No terminal open"), message: String(localized: "Open a login shell to run commands."),
                           action: ("New Terminal", false, { workspace.open() }), compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WorkspaceStyle.content)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: Control.hairline) }
        .accessibilityIdentifier("terminal-panel")
        .onChange(of: theme) { updateThemes() }
        .onChange(of: scheme) { updateThemes() }
        .onChange(of: tone.base) { updateThemes() }
    }

    private func updateThemes() {
        for tab in workspace.tabs {
            for session in tab.sessions.values {
                session.terminal?.applyTheme(TerminalTheme(rawValue: theme) ?? .github, dark: scheme == .dark, tone: tone)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Control.gap) {
            ScrollView(.horizontal) {
                HStack(spacing: Space.xxs) {
                    ForEach(workspace.tabs) { tab in
                        let selected = workspace.selectedTab == tab.id
                        HStack(spacing: Space.xs) {
                            Button { workspace.selectedTab = tab.id } label: {
                                Label(tab.title, systemImage: "terminal")
                                    .font(.callout.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            Button("Close \(tab.title)", systemImage: "xmark") { workspace.closeTab(tab.id) }
                                .labelStyle(.iconOnly).font(.caption.weight(.semibold)).help("Close \(tab.title)")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, Space.m).frame(height: Control.chipHeight)
                        .background(selected ? tone.soft : .clear, in: .rect(cornerRadius: Control.radius, style: .continuous))
                        .motion(Motion.snappy, value: selected)
                        .contextMenu {
                            let index = workspace.tabs.firstIndex { $0.id == tab.id } ?? 0
                            Button("Move Left") { workspace.moveTab(tab.id, to: index - 1) }.disabled(index == 0)
                            Button("Move Right") { workspace.moveTab(tab.id, to: index + 1) }.disabled(index >= workspace.tabs.count - 1)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            HStack(spacing: Control.gap) {
                Button("New terminal", systemImage: "plus") { workspace.open() }
                    .help("New login shell")
                Button("Split side by side", systemImage: "rectangle.split.2x1") { workspace.selected?.split(.horizontal, demo: workspace.demo) }
                    .help("Split side by side").disabled(workspace.selected == nil)
                Button("Split top and bottom", systemImage: "rectangle.split.1x2") { workspace.selected?.split(.vertical, demo: workspace.demo) }
                    .help("Split top and bottom").disabled(workspace.selected == nil)
                Button("Find in scrollback", systemImage: "magnifyingglass") {
                    guard let tab = workspace.selected else { return }
                    tab.sessions[tab.activePane]?.find()
                }
                .help("Find in scrollback").disabled(workspace.selected == nil)
                Button("Close terminal panel", systemImage: "xmark") { workspace.closePanel() }
                    .help("Close panel and end its sessions (⌃`)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.iconAction)
        }
        .padding(Space.s)
    }
}

private struct TerminalSplitView: View {
    let tab: TerminalTab
    let layout: TerminalLayout
    let workspace: TerminalWorkspace

    // Type erasure bounds the recursive split tree's SwiftUI type.
    var body: some View {
        switch layout {
        case .pane(let id):
            if let session = tab.sessions[id] {
                VStack(spacing: 0) {
                    if tab.sessions.count > 1 || session.status != nil {
                        let title = session.status ?? tab.title
                        HStack {
                            if session.status != nil {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(title)
                            Spacer()
                            Button("Close pane", systemImage: "xmark") {
                                if tab.closePane(id) { workspace.closeTab(tab.id) }
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, Space.xxs)
                        .background(tab.activePane == id ? Color.primary.opacity(0.06) : .clear)
                    }
                    TerminalSurface(session: session, tab: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 100, minHeight: 70)
                .accessibilityIdentifier("terminal-pane")
            }
        case .split(_, .horizontal, let first, let second):
            HSplitView {
                child(first)
                child(second)
            }
        case .split(_, .vertical, let first, let second):
            VSplitView {
                child(first)
                child(second)
            }
        }
    }

    private func child(_ layout: TerminalLayout) -> AnyView {
        AnyView(TerminalSplitView(tab: tab, layout: layout, workspace: workspace))
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    let tab: TerminalTab
    @AppStorage("terminalTheme") private var theme = "github"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.productTone) private var tone

    func makeNSView(context: Context) -> NSView {
        // An owned host allows the same PTY view to move when a split reparents its pane.
        let host = TerminalHostView(session: session, tab: tab)
        let terminal = session.makeTerminal { [weak tab, weak session] in
            if let session, tab?.activePane != session.id { tab?.activePane = session.id }
        }
        terminal.applyTheme(TerminalTheme(rawValue: theme) ?? .github, dark: scheme == .dark, tone: tone)
        terminal.removeFromSuperview()
        terminal.frame = host.bounds.insetBy(dx: Space.m, dy: Space.m)
        terminal.autoresizingMask = [.width, .height]
        host.addSubview(terminal)
        host.setBackground(terminal.nativeBackgroundColor)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.terminal?.applyTheme(TerminalTheme(rawValue: theme) ?? .github, dark: scheme == .dark, tone: tone)
        if let terminal = session.terminal { (nsView as? TerminalHostView)?.setBackground(terminal.nativeBackgroundColor) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Switching tabs is temporary. Session ownership handles permanent teardown.
        for child in nsView.subviews { child.removeFromSuperview() }
    }
}

@MainActor
private final class TerminalHostView: NSView {
    private weak var session: TerminalSession?
    private weak var tab: TerminalTab?

    init(session: TerminalSession, tab: TerminalTab) {
        self.session = session
        self.tab = tab
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    /// The inset around the text shows the host, so it must match the terminal's own background.
    func setBackground(_ color: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Focus only inside the user's already-key window. Demo/background windows stay behind.
        if let session, tab?.activePane == session.id, let window, window.isKeyWindow,
           let terminal = session.terminal {
            window.makeFirstResponder(terminal)
        }
    }
}
