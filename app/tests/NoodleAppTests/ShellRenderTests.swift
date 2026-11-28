import SwiftUI
import Testing
@testable import NoodleApp

/// The A1 gate: the whole window, every route, at the default and the minimum window size, light; dark at the minimum.
/// PNGs land in `app/.build/render/shell-<route>-<width>x<height>[-dark].png`.
/// An extension of `PageRenderTests`, so it shares that suite's serialization: both use one demo environment.
@MainActor extension PageRenderTests {
    /// Dark mode only at the minimum: the default-size dark look is covered by the page and design-system renders, and each render costs about 2 s.
    private static let shellRenders: [(size: CGSize, dark: Bool)] = [
        (WorkspaceStyle.defaultWindowSize, false), (WorkspaceStyle.minWindowSize, false), (WorkspaceStyle.minWindowSize, true),
    ]

    @Test(arguments: Route.allCases) func shellRendersEveryRoute(_ route: Route) async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        let saved = env.nav.route
        defer { env.nav.route = saved }
        env.nav.search = ""
        env.nav.open(.route(route))
        for (size, dark) in Self.shellRenders {
            let name = "shell-\(route.rawValue)-\(Int(size.width))x\(Int(size.height))" + (dark ? "-dark" : "")
            let r = await RenderHarness.render(RootView(env: env), name: name, size: size, dark: dark)
            #expect(r.inkRatio > 0.02, "\(name) rendered blank")
            // A short sidebar scrolls, and it keeps the selected row in view. The old Tools section is gone.
            #expect(r.contains(route.title), "\(name) is missing \"\(route.title)\". Saw: \(r.labels.prefix(40))")
            #expect(!r.labels.contains("Tools"), "\(name) still shows the Tools section")
        }
    }
}
