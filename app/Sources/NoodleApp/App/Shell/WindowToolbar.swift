import SwiftUI
import SystemConfiguration

/// The one header for every mode, drawn in the page (not NSToolbar, whose items do not follow a window that shrinks).
/// Leading: host chip, mode switcher (and the sidebar toggle and section tabs once the sidebar hides). Trailing, in this
/// order: page search, page actions, the Models picker, Terminal. Every item is `Control.height` tall on the control
/// surface, `Space.s` apart, `Space.toolbarInset` from the edge.
struct WindowToolbar: View {
    let env: AppEnvironment
    let terminal: TerminalWorkspace
    let sidebarHidden: Bool
    let pageActions: [PageAction]
    /// The detail column's width, measured on the page below: the header cannot measure itself, since it grows past its column.
    let width: CGFloat
    let toggleSidebar: () -> Void

    /// The header's own height, which pages start below.
    static let height: CGFloat = 52
    /// The close, minimise and zoom buttons, which the header clears once the sidebar no longer sits under them.
    private static let windowButtons: CGFloat = 90

    var body: some View {
        // The fullest header that fits: all names, then only the selected mode and page named, then icons only.
        // Measured, not a width threshold: what fits depends on the page's actions and on whether the sidebar is hidden.
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
            // Leading-aligned, so a header that still cannot fit loses its trailing end instead of sliding under
            // the window buttons or the sidebar.
            row(compact: true, tight: true).frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: Self.height, alignment: .leading)
    }

    private func row(compact: Bool, tight: Bool = false) -> some View {
        HStack(spacing: Space.m) {
            // With the sidebar shown its toggle sits at the right end of the sidebar; hidden, it comes here.
            if sidebarHidden { SidebarToggle(hidden: true, action: toggleSidebar) }
            HostChip(env: env, compact: compact)
                .layoutPriority(1)
                .help(env.sidebarStatusText)
                .accessibilityElement(children: .combine)
                .accessibilityValue(env.sidebarStatusText)
                .accessibilityIdentifier("toolbar-host")
            ModeSwitcher(nav: env.nav, compact: compact, iconsOnly: tight).fixedSize()
            // The sidebar lists the sections when it shows; a mode with one page has nothing to switch.
            if sidebarHidden, env.nav.mode.routes.count > 1 { SectionPill(env: env, iconsOnly: tight).fixedSize() }
            Spacer(minLength: Space.m)
            ToolbarTrailing(env: env, terminal: terminal, pageActions: pageActions, windowWidth: width, compact: compact)
        }
        .padding(.leading, sidebarHidden ? Self.windowButtons : Space.toolbarInset)
        .padding(.trailing, Space.toolbarInset)
        .frame(minWidth: width, alignment: .leading)
    }
}

/// The sidebar toggle in the app's control style. One copy shows at a time: in the sidebar, or in the toolbar once it hides.
struct SidebarToggle: View {
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        Button(hidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left", action: action)
            .labelStyle(.iconOnly).buttonStyle(.iconAction)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(hidden ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)")
            .accessibilityLabel(hidden ? "Show Sidebar" : "Hide Sidebar")
            .accessibilityIdentifier("toolbar-sidebar-toggle")
    }
}

/// Search, page actions, the Models picker and Terminal as one toolbar item, `Space.toolbarInset` from the trailing edge.
private struct ToolbarTrailing: View {
    let env: AppEnvironment
    let terminal: TerminalWorkspace
    let pageActions: [PageAction]
    let windowWidth: CGFloat
    let compact: Bool
    @FocusState private var searchFocused: Bool
    /// The folded search was opened; it folds again once it loses focus while empty.
    @State private var searchOpen = false
    private static let searchWidth: CGFloat = 220
    /// Below this column width the header has no room for the full field.
    private static let foldBelow: CGFloat = 900

    private var searchFolded: Bool { windowWidth < Self.foldBelow && env.nav.search.isEmpty && !searchOpen }

    var body: some View {
        HStack(spacing: Space.s) {
            if env.nav.hasSearch {
                ToolbarSearch(nav: env.nav, focused: $searchFocused, open: $searchOpen, folded: searchFolded)
                    .frame(width: searchFolded ? Control.height : Self.searchWidth)
            }
            controls.fixedSize()
        }
        .motion(Motion.snappy, value: searchFolded)
        .onChange(of: env.nav.route) { searchOpen = false }
    }

    private var controls: some View {
        HStack(spacing: Space.s) {
            ForEach(pageActions) { action in
                Button(action.title, systemImage: action.symbol) { action.run() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(ControlButtonStyle(tint: .primary, square: action.iconOnly))
                    .disabled(action.disabled)
                    .help(action.help ?? action.title)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier("toolbar-\(action.id)")
            }
            if env.nav.route == .containers, !env.nav.selectedContainers.isEmpty {
                ContainerToolbarButtons(env: env)
            }
            if env.nav.route == .chat {
                let store = ModelsPage.sharedStore(demo: env.demo)
                ModelChatToolbarControls(store: store, compact: compact)
                if !compact {
                    ModelWorkspaceHeader(store: store, selected: store.selectedModel, select: { store.selectedModelID = $0 })
                        .toolbarPicker
                }
            }
            Button("Terminal", systemImage: "terminal") { terminal.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(tint: terminal.isOpen ? WorkspaceStyle.accent : .primary, square: true))
                .help("Toggle terminal (⌃`)")
                .accessibilityLabel("Terminal")
                .accessibilityIdentifier("toolbar-terminal")
        }
    }
}

/// The page search field. Command-F focuses it, Escape clears it. Folded, it is a 32 pt magnifier that opens the field.
private struct ToolbarSearch: View {
    let nav: NavigationModel
    var focused: FocusState<Bool>.Binding
    @Binding var open: Bool
    let folded: Bool

    var body: some View {
        @Bindable var nav = nav
        let prompt = String(localized: "Search \(nav.route.title.lowercased())")
        Group {
            if folded {
                Button(prompt, systemImage: "magnifyingglass") { open = true; focused.wrappedValue = true }
                    .labelStyle(.iconOnly).buttonStyle(.iconAction)
                    .help(prompt)
                    .accessibilityLabel(prompt)
            } else {
                SearchField(prompt: prompt, text: $nav.search, focus: focused)
                    .onExitCommand { nav.search = ""; focused.wrappedValue = false; open = false }
                    .onChange(of: focused.wrappedValue) { _, now in if !now { open = false } }
            }
        }
        .background { Button("Find") { open = true; focused.wrappedValue = true }.keyboardShortcut("f").hidden() }
        .accessibilityIdentifier("toolbar-search")
    }
}

extension NavigationModel {
    /// The Overview and Models filter nothing, and macOS machines have no list, so they show no search field.
    var hasSearch: Bool {
        !(route == .overview || route == .runners || route.isModels || (route == .machines && machinePlatform == .macOS))
    }
}

private struct SidebarStatusDot: View {
    let env: AppEnvironment

    var body: some View {
        let summary = env.runtimeSummary
        Group {
            if summary.busy { ProgressView().controlSize(.mini) } else { StateDot(state: summary.running ? "running" : "exited", size: 8) }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: summary.running)
    }
}

/// Engine dot plus this Mac's name, the way a terminal shows the host it is attached to.
struct HostChip: View {
    let env: AppEnvironment
    var compact = false
    // Read from the local configuration store; Host.current() can wait on DNS.
    private static let macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"

    var body: some View {
        // Whole label or dot only, never a squeezed label: a crowded toolbar drops the text before it truncates it.
        ViewThatFits(in: .horizontal) {
            if !compact { chip(label: true).fixedSize() }
            chip(label: false)
        }
    }

    private func chip(label: Bool) -> some View {
        HStack(spacing: Space.s) {
            SidebarStatusDot(env: env).frame(width: 10, height: Control.height)
            if label {
                Text("Noodle").fontWeight(.semibold)
                Text("Beta").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                    .background(.quaternary, in: Capsule())
                Text(env.demo ? "Mac" : Self.macName).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, Space.m)
        .frame(height: Control.height)
        .controlSurface()
        .contentShape(.rect(cornerRadius: Control.radius))
    }
}

extension AppEnvironment {
    /// Same text the sidebar card shows, for the toolbar dot's help and accessibility value.
    var sidebarStatusText: String { runtimeSummary.text }
}
