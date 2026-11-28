import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// The header never draws under the window buttons or the sidebar, however narrow its column is.
/// An extension of `PageRenderTests`, so it shares that suite's serialization: both use one demo environment.
@MainActor extension PageRenderTests {
    /// (column width, sidebar hidden, first x the header may draw at)
    private static let fits: [(width: CGFloat, hidden: Bool, clear: CGFloat)] = [
        (480, true, 88), (680, true, 88), (900, true, 88), (1100, true, 88),
        (440, false, Space.toolbarInset - 2), (760, false, Space.toolbarInset - 2),
    ]

    @Test func headerStaysClearOfTheWindowButtons() async throws {
        let env = RenderHarness.env
        let saved = env.nav.route
        defer { env.nav.route = saved }
        env.nav.open(.route(.chat))
        let terminal = TerminalWorkspace(socketPath: env.paths.socket.path, docker: TerminalLaunch.docker(paths: env.paths), demo: true)
        for fit in Self.fits {
            let size = CGSize(width: fit.width, height: WindowToolbar.height)
            let name = "toolbar-\(Int(fit.width))-\(fit.hidden ? "hidden" : "shown")"
            let view = WindowToolbar(env: env, terminal: terminal, sidebarHidden: fit.hidden, pageActions: [], width: fit.width) {}
                .frame(width: fit.width, height: WindowToolbar.height)
            let r = await RenderHarness.render(view, name: name, size: size, recognizeText: false)
            let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: r.png)))
            let first = try #require(Self.firstInkColumn(rep), "\(name) rendered blank")
            let x = CGFloat(first) * fit.width / CGFloat(rep.pixelsWide)
            #expect(x >= fit.clear, "\(name) draws at x=\(x), left of \(fit.clear)")
        }
    }

    /// The first pixel column that differs from the top-left background pixel.
    private static func firstInkColumn(_ rep: NSBitmapImageRep) -> Int? {
        guard let bg = rep.colorAt(x: 0, y: 0) else { return nil }
        for x in 0..<rep.pixelsWide {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.06 { return x }
            }
        }
        return nil
    }
}
