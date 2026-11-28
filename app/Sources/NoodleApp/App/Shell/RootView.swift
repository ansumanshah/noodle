import SwiftUI

struct RootView: View {
    let env: AppEnvironment
    @State private var visibility: NavigationSplitViewVisibility = DemoFlags.sidebarHidden ? .detailOnly : .all
    /// What AppKit really shows. It can differ from `visibility` after AppKit expands or collapses the column itself.
    @State private var sidebarCollapsed = DemoFlags.sidebarHidden
    @State private var terminal: TerminalWorkspace
    /// The current page's toolbar buttons, drawn by `WindowToolbar`.
    @State private var pageActions: [PageAction] = []
    @State private var detailWidth: CGFloat = 1000
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(env: AppEnvironment) {
        self.env = env
        _terminal = State(initialValue: TerminalWorkspace(socketPath: env.paths.socket.path,
                                                         docker: TerminalLaunch.docker(paths: env.paths), demo: env.demo))
    }

    var body: some View {
        @Bindable var nav = env.nav
        let showsInspector = nav.route == .containers && nav.detailContainer.flatMap { env.containers.container($0) } != nil
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(env: env) { visibility = .detailOnly }
                // The app's own toggle sits at the top of the sidebar, beside the window buttons.
                .toolbar(removing: .sidebarToggle)

                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            detailColumn
            .navigationTitle(env.nav.selectedProject ?? (nav.route == .containers ? "Workspace" : nav.route.title))
            .navigationSubtitle(subtitle)
            .background(WorkspaceStyle.content)
        }
        .motion(Motion.snappy, value: visibility)
        // Each page draws its own heading, so the toolbar repeats neither the title nor a second background.
        .toolbar(removing: .title)
        // An invisible item keeps the native toolbar at full height, so the window buttons centre on the 52 pt header
        // instead of riding up in a collapsed title bar.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: 1, height: Control.height).accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(SidebarCollapseReader(initial: DemoFlags.sidebarHidden ? true : nil) { collapsed in
            sidebarCollapsed = collapsed
            // Keep the binding in step, so the next toggle starts from what is on screen.
            let shown: NavigationSplitViewVisibility = collapsed ? .detailOnly : .all
            if (visibility == .detailOnly) != collapsed { visibility = shown }
        }.frame(width: 0, height: 0))
        .background(TerminalWindowBinding(workspace: terminal).frame(width: 0, height: 0))
        .background(WorkspaceWindow(showsInspector: showsInspector))
        .background(CompactScrollbars().id(nav.route).frame(width: 0, height: 0))
        .scrollIndicators(.never)
        .focusedSceneValue(\.terminalWorkspace, terminal)
        .sheet(isPresented: $nav.showSetup) { SetupSheet(env: env).compactScrollbars() }
        .sheet(isPresented: $nav.showWelcome) { WelcomeSheet(env: env).compactScrollbars() }
        .sheet(isPresented: $nav.showDockerDefault) { DockerDefaultSheet(env: env) }
        .sheet(isPresented: $nav.showUninstall) { UninstallNoodleSheet(env: env) }
        .confirmationDialog(
            nav.confirmation?.title ?? "", isPresented: Binding(get: { nav.confirmation != nil }, set: { if !$0 { nav.confirmation = nil } }),
            titleVisibility: .visible, presenting: nav.confirmation
        ) { c in
            Button(c.confirmLabel, role: .destructive) { Task { await c.action() } }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.message) }
        .overlay(alignment: .top) {
            if let message = env.connection.message, !nav.route.isModels {
                ErrorBanner(message: message) { env.connection.message = nil }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let name = env.firstStart.containerName {
                FirstStartCard(name: name, repository: FirstStartNotice.repository, dismiss: env.firstStart.dismiss)
                    .padding(.trailing, Space.panel).padding(.bottom, Space.panel)
                    .transition(.opacity)
            }
        }
        .motion(Motion.snappy, value: env.firstStart.containerName)
        // Sidebar, toolbar and terminal sit outside DetailRouter, so the mode tone is set here too.
        .environment(\.productTone, nav.route.tone)
        .tint(WorkspaceStyle.accent)
        .accentColor(WorkspaceStyle.accent)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .frame(minWidth: WorkspaceStyle.minWindowSize.width, minHeight: WorkspaceStyle.minWindowSize.height)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            env.sync.setWindowVisible(true)
            if env.demo, CommandLine.arguments.contains("--demo-terminal"), !terminal.isOpen { terminal.open() }
            if let id = env.demoSelect, let c = env.containers.items.first(where: { $0.name == id || $0.id == id }) { env.nav.open(container: c.id) }
        }
        .onChange(of: env.containers.loaded) { _, loaded in
            if loaded, let id = env.demoSelect, let c = env.containers.items.first(where: { $0.name == id || $0.id == id }) { env.nav.open(container: c.id) }
        }
        .onChange(of: nav.route) { _, _ in nav.search = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await env.sync.refreshDockerTarget() }
        }
        .onChange(of: env.connection.phase) { _, phase in
            // First launch: the welcome, once, in place of the Docker assistant. It covers Models too, so any page qualifies.
            if case .down = phase, !env.containers.loaded, !nav.showsMacMachine, !nav.showSetup, !nav.showUninstall,
               WelcomeFlow.shouldShow(scripted: env.demo || WelcomeSheet.scripted, needsSetup: env.connection.needsSetup,
                                      canChangeInstallation: nav.canChangeInstallation) {
                UserDefaults.standard.set(true, forKey: WelcomeFlow.shownKey)
                nav.showWelcome = true
            }
        }
    }

    /// The page under the header, with the terminal panel below it.
    private var detailColumn: some View {
        VSplitView {
                DetailRouter(env: env, sidebarHidden: sidebarCollapsed)
                    .onPreferenceChange(PageActionsKey.self) { pageActions = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                    .padding(.top, WindowToolbar.height)
                    .overlay(alignment: .top) {
                        WindowToolbar(env: env, terminal: terminal, sidebarHidden: sidebarCollapsed, pageActions: pageActions,
                                      width: detailWidth) {
                            visibility = sidebarCollapsed ? .all : .detailOnly
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .frame(minHeight: 120)
                if terminal.isOpen {
                    TerminalPanel(workspace: terminal)
                        .frame(minHeight: 160, idealHeight: 240)
                        .transition(reduceMotion ? .identity : .slide(from: .bottom))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: terminal.isOpen)
    }

    private var subtitle: String {
        if env.nav.showsMacMachine { return env.macMachine.statusText }
        switch env.connection.phase {
        case .up: return ""
        case .connecting: return "Connecting…"
        case .down: return "Not running"
        }
    }
}
