import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

/// Every page with nothing in it, rendered in the full window. Runs only when the process starts with
/// `NOODLE_DEMO=empty`, because the demo environment is a process-wide singleton:
///
///     NOODLE_DEMO=empty swift test --filter EmptyPagesRenderTests
///
/// PNGs land in `app/.build/render/empty-*.png`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NOODLE_DEMO"] == "empty"))
struct EmptyPagesRenderTests {
    private let size = CGSize(width: 1080, height: 720)

    private func shot(_ route: Route, platform: MachinePlatform = .linux, dark: Bool = false, shows: [String]) async {
        let env = RenderHarness.env
        await env.sync.refreshNow()
        env.nav.search = ""
        env.nav.route = route
        env.nav.machinePlatform = platform
        let name = "empty-\(route.rawValue)" + (platform == .macOS ? "-macos" : "") + (dark ? "-dark" : "")
        let r = await RenderHarness.render(RootView(env: env), name: name, size: size, dark: dark, settle: .milliseconds(1600))
        #expect(r.inkRatio > 0.02, "\(name) rendered blank")
        for needle in shows {
            #expect(r.contains(needle), "\(name) is missing \"\(needle)\". Saw: \(r.labels.prefix(40))")
        }
    }

    @Test func overview() async { await shot(.overview, shows: ["Overview"]) }
    @Test func containers() async { await shot(.containers, shows: ["No containers"]) }
    @Test func images() async { await shot(.images, shows: ["No images"]) }
    @Test func volumes() async { await shot(.volumes, shows: ["No volumes"]) }
    @Test func networks() async { await shot(.networks, shows: ["Networks"]) }
    @Test func linuxMachines() async { await shot(.machines, shows: ["New Machine"]) }
    @Test func macMachines() async { await shot(.machines, platform: .macOS, shows: ["macOS"]) }
    @Test func kubernetes() async { await shot(.kubernetes, shows: ["Kubernetes"]) }
    @Test func builds() async { await shot(.builds, shows: ["No builds yet"]) }
    @Test func chat() async { await shot(.chat, shows: ["Models", "Chat"]) }
    @Test func library() async { await shot(.library, shows: ["Library", "Download"]) }
    @Test func connections() async { await shot(.connections, shows: ["Connections"]) }
    @Test func containersDark() async { await shot(.containers, dark: true, shows: ["No containers"]) }
    @Test func imagesDark() async { await shot(.images, dark: true, shows: ["No images"]) }
}
