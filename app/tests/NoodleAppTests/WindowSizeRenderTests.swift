import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// Every page in the full window at the default and the minimum size, to look for clipped or overflowing content.
/// Opt in, since it renders 2 x 15 windows:
///
///     NOODLE_WINDOW_SIZES=1 swift test --filter WindowSizeRenderTests
///
/// PNGs land in `app/.build/render/size-<default|min>-<route>.png`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NOODLE_WINDOW_SIZES"] == "1"))
struct WindowSizeRenderTests {
    @Test(arguments: [("default", WorkspaceStyle.defaultWindowSize), ("min", WorkspaceStyle.minWindowSize)])
    func everyPageRenders(label: String, size: CGSize) async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        // More chats than the sidebar shows, so the Models renders include the nested rows and "Show all".
        let chat = ModelsPage.sharedStore(demo: true).chat
        while chat.conversations.count <= SidebarChats.visibleLimit {
            chat.beginNewConversation()
            chat.appendUser("Chat number \(chat.conversations.count) about a long trip plan", modelID: nil)
        }
        for route in Route.allCases {
            env.nav.search = ""
            env.nav.route = route
            let r = await RenderHarness.render(RootView(env: env), name: "size-\(label)-\(route.rawValue)", size: size,
                                               settle: .milliseconds(1200))
            #expect(r.inkRatio > 0.02, "\(label) \(route.rawValue) rendered blank")
        }
    }
}
