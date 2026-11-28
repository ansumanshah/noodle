import SwiftUI
import Testing
@testable import NoodleApp

@MainActor @Suite struct SidebarRuntimeTests {
    @Test func cardFollowsTheRuntimeBehindTheSelectedItem() {
        for route in [Route.overview, .containers, .images, .volumes, .networks, .builds] {
            #expect(SidebarRuntime.forRoute(route, platform: .linux) == .engine, "\(route)")
        }
        #expect(SidebarRuntime.forRoute(.machines, platform: .linux) == .linuxMachine)
        #expect(SidebarRuntime.forRoute(.machines, platform: .macOS) == .macMachine)
        #expect(SidebarRuntime.forRoute(.kubernetes, platform: .linux) == .kubernetes)
        #expect(SidebarRuntime.forRoute(.runners, platform: .linux) == .runners)
        #expect(SidebarRuntime.forRoute(.runnerCaches, platform: .linux) == .runners)
        for route in Route.Mode.models.routes {
            #expect(SidebarRuntime.forRoute(route, platform: .linux) == .models, "\(route)")
        }
    }

    /// Start and Stop moved from the Models toolbar to the sidebar card. The shared control keeps its colours,
    /// labels and accessibility identifiers wherever it is placed.
    @Test func modelServerControlShowsStopWhenRunningAndStartWhenNot() async {
        let running = ModelsPageStore(demo: true, demoState: .running)
        let stopped = ModelsPageStore(demo: true, demoState: .installed)
        let on = await RenderHarness.render(ModelServerControl(store: running, selected: running.selectedModel)
            .padding(12), name: "model-server-control-running", size: CGSize(width: 200, height: 60), compositeAppKitControls: false)
        let off = await RenderHarness.render(ModelServerControl(store: stopped, selected: stopped.selectedModel)
            .padding(12), name: "model-server-control-stopped", size: CGSize(width: 200, height: 60), compositeAppKitControls: false)
        #expect(on.contains("Stop") && !on.contains("Start"))
        #expect(off.contains("Start") && !off.contains("Stop"))
    }

    @Test func pickerChoiceLivesInTheStoreSoTheCardStartsTheSameModel() {
        let store = ModelsPageStore(demo: true, demoState: .installed)
        #expect(store.selectedModel?.id == store.models.first?.id)
        store.selectedModelID = store.models.last?.id
        #expect(store.selectedModel?.id == store.models.last?.id)
    }

    @Test func chatsNestUnderChatAndArrowsWalkThem() {
        let ids = [UUID(), UUID()]
        #expect(SidebarView.rowIDs(mode: .models, projects: [], chats: ids)
            == ["chat"] + ids.map(SidebarView.conversationID) + ["create", "library", "apps", "connections"])
        let history = ModelChatHistory()
        for index in 0..<(SidebarChats.visibleLimit + 2) {
            history.beginNewConversation()
            history.appendUser("chat \(index)", modelID: nil)
        }
        let all = history.conversations
        let oldest = all.last!.id
        #expect(SidebarChats.visible(all, selected: nil, showsAll: false).count == SidebarChats.visibleLimit)
        #expect(SidebarChats.visible(all, selected: oldest, showsAll: false).last?.id == oldest)
        #expect(SidebarChats.visible(all, selected: nil, showsAll: true).count == all.count)
        #expect(SidebarChats.visible(all, selected: nil, showsAll: false, limit: SidebarChats.compactLimit).count
            == SidebarChats.compactLimit)
    }

    /// The demo sidebar lists chats under the Chat row, and picking one from another Models row opens it in Chat.
    @Test func demoSidebarListsChatsAndSelectingOneOpensChat() async {
        let store = ModelsPageStore(demo: true, demoState: .running)
        store.chat.beginNewConversation()
        store.chat.appendUser("Plan a trip to Goa", modelID: nil)
        let rows = List { SidebarChats(store: store, tone: WorkspaceStyle.models, selectedID: store.chat.selectedID,
                                       showsAll: .constant(false), open: { _ in }, delete: { _ in }) }
            .listStyle(.sidebar).frame(width: 232)
        let text = await RenderHarness.render(rows, name: "sidebar-chats", size: CGSize(width: 260, height: 200))
        #expect(text.contains("Plan a trip"))

        // Synchronous from here, so no other test sees the shared demo store's extra chat or the changed route.
        let env = RenderHarness.env
        let route = env.nav.route
        defer { env.nav.route = route }
        let shared = ModelsPage.sharedStore(demo: true)
        shared.chat.beginNewConversation()
        let id = shared.chat.appendUser("Sidebar chat", modelID: nil)
        shared.chat.beginNewConversation()
        let newer = shared.chat.appendUser("Newer chat", modelID: nil)
        defer { shared.deleteConversation(id); shared.deleteConversation(newer) }
        env.nav.route = .library
        SidebarView(env: env).selection.wrappedValue = SidebarView.conversationID(id)
        #expect(env.nav.route == .chat)
        #expect(shared.chat.selectedID == id)
        #expect(SidebarView(env: env).selection.wrappedValue == SidebarView.conversationID(id))
    }
}
