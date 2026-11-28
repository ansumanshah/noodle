import NoodleCore
import SwiftUI

/// One sidebar that lists only the selected mode's pages (Compose projects sit under Compose).
struct SidebarView: View {
    let env: AppEnvironment
    /// Hides the sidebar; the toggle sits at its top right, level with the window buttons.
    var hide: () -> Void = {}

    var selection: Binding<String?> {
        Binding(get: {
            if env.nav.route == .compose, let project = env.nav.selectedProject { return Self.projectID(project) }
            if env.nav.route == .chat, let id = chatStore?.chat.selectedID { return Self.conversationID(id) }
            return env.nav.route.rawValue
        }, set: { value in
            guard let value else { return }
            env.nav.selectedContainers = []
            env.nav.detailContainer = nil
            env.nav.search = ""
            if value.hasPrefix(Self.projectPrefix) {
                env.nav.selectedProject = String(value.dropFirst(Self.projectPrefix.count))
                env.nav.route = .compose
            } else if value.hasPrefix(Self.conversationPrefix), let id = UUID(uuidString: String(value.dropFirst(Self.conversationPrefix.count))) {
                env.nav.selectedProject = nil
                env.nav.route = .chat
                chatStore?.selectConversation(id)
            } else if let route = Route(rawValue: value) {
                env.nav.selectedProject = nil
                env.nav.route = route
            }
        })
    }

    private static let projectPrefix = "project:"
    static func projectID(_ name: String) -> String { projectPrefix + name }
    private static let conversationPrefix = "chat:"
    static func conversationID(_ id: UUID) -> String { conversationPrefix + id.uuidString }

    /// Every row of a mode in the order arrows walk them, with projects after Compose and chats after Chat.
    static func rowIDs(mode: Route.Mode, projects: [String], chats: [UUID] = []) -> [String] {
        mode.routes.flatMap { route in
            [route.rawValue] + (route == .compose ? projects.map(projectID) : route == .chat ? chats.map(conversationID) : [])
        }
    }

    /// The Models store while the Models mode shows; its sidebar card makes the same store anyway.
    private var chatStore: ModelsPageStore? { env.nav.mode == .models ? ModelsPage.sharedStore(demo: env.demo) : nil }
    @State private var showsAllChats = false
    @State private var deletingConversation: UUID?

    private var visibleChats: [ModelConversation] {
        guard let chat = chatStore?.chat else { return [] }
        return SidebarChats.visible(chat.conversations, selected: chat.selectedID, showsAll: showsAllChats, limit: chatLimit)
    }
    private var chatLimit: Int { compactCard ? SidebarChats.compactLimit : SidebarChats.visibleLimit }

    /// The row an up or down arrow lands on; it stops at either end.
    static func row(after current: String, in ids: [String], down: Bool) -> String? {
        guard let index = ids.firstIndex(of: current) else { return nil }
        return ids[min(ids.count - 1, max(0, index + (down ? 1 : -1)))]
    }

    private var projects: [ContainerGroup] { env.containers.groups.filter { $0.project != nil && !AIApp.isAppProject($0.project) } }

    private var composeProjects: [ComposeProjectInfo] { ComposeProjects.group(env.containers.items) }

    /// Below this sidebar height the card drops its resource rows, so the navigation keeps room for every row.
    nonisolated private static let compactCardHeight: CGFloat = 700
    @State private var compactCard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            navigation
            VMStatusPager(env: env, compact: compactCard)
        }
        .background(WorkspaceStyle.sidebar)
        .overlay(alignment: .topTrailing) {
            SidebarToggle(hidden: false, action: hide)
                .frame(height: WindowToolbar.height)
                .padding(.trailing, Space.m)
                .ignoresSafeArea(.container, edges: .top)
        }
        .motion(Motion.standard, value: env.nav.mode)
        .task(id: env.sidebarRuntime == .runners) {
            env.runnerRepos.reload(env: env)
            guard env.sidebarRuntime == .runners else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); env.runnerRepos.reload(env: env) }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < Self.compactCardHeight } action: { compactCard = $0 }
        .alert("Delete conversation?", isPresented: $deletingConversation.isPresent()) {
            Button("Delete", role: .destructive) {
                if let id = deletingConversation { chatStore?.deleteConversation(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the conversation from this Mac.")
        }
    }

    /// The list ends where the card begins, so rows never sit behind it. At a short window the list scrolls, and
    /// the selected row is kept in view so it is never the one that is clipped.
    private var navigation: some View {
        ScrollViewReader { proxy in
            navigationList
                .onAppear { reveal(proxy) }
                .onChange(of: selection.wrappedValue) { reveal(proxy) }
                .onChange(of: compactCard) { reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = selection.wrappedValue else { return }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }

    /// Download progress for the Library row, read only from a store that already exists.
    private var libraryBadge: String? {
        ModelLibraryPolicy.badge(ModelsPage.existingStore(demo: env.demo)?.downloadProgress)
    }

    private var navigationList: some View {
        List {
            ForEach(env.nav.mode.routes) { route in
                row(route, badge: badge(route), detail: detail(route))
                if route == .chat, let store = chatStore {
                    SidebarChats(store: store, tone: route.tone,
                                 selectedID: env.nav.route == .chat ? store.chat.selectedID : nil,
                                 showsAll: $showsAllChats, limit: chatLimit,
                                 open: { selection.wrappedValue = Self.conversationID($0) },
                                 delete: { deletingConversation = $0 })
                }
                if route == .compose {
                    ForEach(projects) { group in
                        let name = group.project ?? ""
                        SidebarRow(title: name, symbol: "square.stack", tone: WorkspaceStyle.containers,
                                   selected: selection.wrappedValue == Self.projectID(name), nested: true,
                                   badge: group.runningCount > 0 ? "\(group.runningCount)" : nil,
                                   detail: String(localized: "\(group.runningCount) of \(group.containers.count) services running")) {
                            selection.wrappedValue = Self.projectID(name)
                        }
                        .id(Self.projectID(name))
                    }
                }
            }
        }
        .id(env.nav.mode)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .listStyle(.sidebar)
        // The page margin under the header, as on every page, so the first row shares the page's first control line.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Space.page) }
        .scrollContentBackground(.hidden)
        // Short rows: a permanent scroller beside them is noise. Scrolling still works.
        .scrollIndicators(.never)
        .onMoveCommand { direction in
            guard direction == .up || direction == .down, let current = selection.wrappedValue,
                  let next = Self.row(after: current, in: Self.rowIDs(mode: env.nav.mode, projects: projects.compactMap(\.project),
                                                            chats: visibleChats.map(\.id)),
                                      down: direction == .down) else { return }
            selection.wrappedValue = next
        }
    }

    private func badge(_ route: Route) -> String? {
        switch route {
        case .library: libraryBadge
        case .containers: env.containers.runningCount > 0 ? "\(env.containers.runningCount)" : nil
        case .compose: composeProjects.isEmpty ? nil : "\(composeProjects.count)"
        default: nil
        }
    }

    private func detail(_ route: Route) -> String? {
        switch route {
        case .library: libraryBadge.map { "Downloading " + $0.dropFirst(2) }
        case .containers: String(localized: "\(env.containers.runningCount) running")
        default: nil
        }
    }

    private func row(_ route: Route, badge: String? = nil, detail: String? = nil) -> some View {
        SidebarRow(title: route.title, symbol: route.symbol, tone: route.tone,
                   selected: selection.wrappedValue == route.rawValue, badge: badge, detail: detail) {
            selection.wrappedValue = route.rawValue
        }
        .id(route.rawValue)
    }
}
