import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// The Overview renders headless with the demo daemon: light, dark, narrow, trouble, empty, and frames of the
/// attention row. Window renders use the 3:2 aspect of the design references.
/// An extension of `PageRenderTests`, so it shares that suite's serialization: both use one demo environment.
@MainActor extension PageRenderTests {
    private var windowSize: CGSize { CGSize(width: 1080, height: 720) }

    private func shot<V: View>(_ view: V, _ name: String, size: CGSize, dark: Bool = false) async -> RenderHarness.Result {
        let env = RenderHarness.env
        env.nav.route = .overview
        let r = await RenderHarness.render(view, name: "overview-" + name, size: size, dark: dark, settle: .milliseconds(2200))
        #expect(r.inkRatio > 0.02, "overview-\(name) rendered blank")
        for word in placeholderWords { #expect(!r.contains(word), "overview shows \"\(word)\"") }
        return r
    }

    private func restore() async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
    }

    @Test func windowLight() async {
        await restore()
        let r = await shot(RootView(env: RenderHarness.env), "light", size: windowSize)
        for needle in ["Projects", "Ports", "Memory", "Disk", "Machines", "shop", "open-webui.localhost", "worker exited with code 1", "Clean Up"] {
            #expect(r.contains(needle), "missing \(needle). Saw: \(r.labels.prefix(40))")
        }
    }

    @Test func windowDark() async {
        await restore()
        _ = await shot(RootView(env: RenderHarness.env), "dark", size: windowSize, dark: true)
    }

    @Test func narrow() async {
        await restore()
        let r = await shot(OverviewPage(env: RenderHarness.env), "narrow", size: CGSize(width: 420, height: 1100))
        #expect(r.contains("Projects"))
        // The page has no hero metrics, engine tile, VM state or CPU count. The window footer is not part of the page.
        for gone in ["Engine", "Wake", "Docker 27", "CPU", "VM awake"] { #expect(!r.contains(gone), "\(gone) must not appear") }
    }

    /// Three problems at once: a failed exit, a restart loop and an unhealthy container.
    @Test func trouble() async {
        let env = RenderHarness.env
        await restore()
        let extra = [
            ContainerSummary(id: "f1" + String(repeating: "a", count: 62), names: ["/shop-cache-1"], image: "redis:7", state: "restarting",
                             status: "Restarting (1) 5 seconds ago", created: Int(Date().timeIntervalSince1970) - 600,
                             labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "cache"]),
            ContainerSummary(id: "f2" + String(repeating: "b", count: 62), names: ["/api-gateway"], image: "gateway:1", state: "running",
                             status: "Up 2 hours (unhealthy)", created: Int(Date().timeIntervalSince1970) - 7000),
        ]
        env.containers.apply(env.containers.items + extra)
        let r = await shot(RootView(env: env), "trouble", size: windowSize)
        #expect(r.contains("cache keeps restarting") || r.contains("keeps restarting"))
        #expect(r.contains("unhealthy"))
        await restore()
    }

    /// Nothing exists: Projects shows only the command.
    @Test func empty() async {
        let env = RenderHarness.env
        await restore()
        env.containers.apply([])
        env.images.apply([])
        let r = await shot(OverviewPage(env: env), "empty", size: CGSize(width: 760, height: 480))
        #expect(r.contains("run -d --name hello -p 8080:80 nginx"))
        await restore()
    }

    @Test func containerActionFailureIsVisibleOnOverview() async {
        let env = RenderHarness.env
        await restore()
        env.containers.actionError = "Port 5432 is already in use"
        defer { env.containers.actionError = nil }
        let r = await shot(OverviewPage(env: env), "action-error", size: windowSize)
        #expect(r.contains("Port 5432 is already in use"))
    }

    @Test func symbolsRender() {
        let symbols = ["square.grid.2x2", "shippingbox", "square.stack", "square.3.layers.3d", "externaldrive", "network",
                       "server.rack", "terminal", "text.alignleft", "doc.on.doc", "arrow.up.forward.square", "play.fill", "stop.fill",
                       "arrow.clockwise", "trash", "exclamationmark.triangle.fill", "checkmark.circle.fill", "xmark.circle.fill"]
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.isEmpty, "symbols that do not render: \(missing)")
    }

    // MARK: frames

    /// Renders the attention row appearing and leaving. Frames go to `app/.build/render/overview-frames/`.
    /// Every frame must be written, and the held frame must differ from both the frame before the row
    /// appeared and the frame after it left, so a page that never changes cannot pass.
    @Test func attentionFrames() async throws {
        let env = RenderHarness.env
        await restore()
        let full = env.containers.items
        let without = full.filter { $0.name != "shop-worker-1" }
        #expect(without.count < full.count, "the demo has no shop-worker-1 to make an attention row appear")
        env.containers.apply(without)
        let host = NSHostingView(rootView: OverviewPage(env: env))
        let size = CGSize(width: 760, height: 420)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        let dir = RenderHarness.outputDir.appendingPathComponent("overview-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await settle(host, size, dir.appendingPathComponent("appear-0.png"))
        var written: [String: Data] = [:]
        func capture(_ name: String) throws {
            let url = dir.appendingPathComponent(name + ".png")
            try save(host, size, url)
            written[name] = try Data(contentsOf: url)
        }
        try capture("appear-0")
        env.containers.apply(full)
        var elapsed = 0
        for (index, ms) in [30, 90, 180, 400].enumerated() {
            try await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms
            try capture("appear-\(index + 1)")
        }
        try await settle(host, size, dir.appendingPathComponent("hold.png"))
        try capture("hold")
        env.containers.apply(without)
        elapsed = 0
        for (index, ms) in [30, 90, 180, 400].enumerated() {
            try await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms
            try capture("leave-\(index + 1)")
        }
        window.contentView = nil
        window.close()
        await restore()
        #expect(written.count == 10, "expected 10 frames, wrote \(written.keys.sorted())")
        #expect(written.values.allSatisfy { !$0.isEmpty }, "an empty frame was written")
        #expect(written["hold"] != written["appear-0"], "the attention row never appeared")
        #expect(written["leave-4"] != written["hold"], "the attention row never left")
    }

    /// Polls until two captures 50 ms apart match, so the page has finished loading and moving.
    private func settle(_ host: NSView, _ size: CGSize, _ url: URL) async throws {
        var last = Data()
        let settled = try await waitUntil(timeout: .seconds(15), poll: .milliseconds(50)) {
            try save(host, size, url)
            let now = try Data(contentsOf: url)
            defer { last = now }
            return now == last
        }
        #expect(settled, "the overview never stopped changing")
    }

    private func save(_ host: NSView, _ size: CGSize, _ url: URL) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        cg.setFillColor(NSColor(white: 0.985, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
        (host.layer?.presentation() ?? host.layer)?.render(in: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
