import Foundation
import SwiftUI
import Testing
@testable import NoodleApp

@MainActor @Suite(.serialized) struct SetupRenderTests {
    // Explicit bitmap mode supports sandboxes where Vision is unavailable. Normal runs still assert text.
    private var bitmapOnly: Bool { ProcessInfo.processInfo.environment["NOODLE_RENDER_BITMAP_ONLY"] == "1" }

    private func expectShows(_ render: RenderHarness.Result, _ text: [String], minimumInk: Double = 0.02,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(render.inkRatio > minimumInk, "Rendered blank", sourceLocation: sourceLocation)
        if !bitmapOnly {
            for needle in text { #expect(render.contains(needle), "Missing \(needle): \(render.text)", sourceLocation: sourceLocation) }
        }
    }

    @Test(arguments: [false, true]) func uninstallConfirmation(dark: Bool) async {
        let flow = UninstallFlow { _ in .init(code: 0, output: "Fixture only") }
        let r = await RenderHarness.render(UninstallNoodleSheet(env: RenderHarness.env, flow: flow),
                                           name: "setup-uninstall-\(dark ? "dark" : "light")",
                                           size: CGSize(width: 560, height: 640), dark: dark, recognizeText: !bitmapOnly)
        #expect(!flow.deleteData)
        expectShows(r, ["Uninstall Noodle?", "LaunchAgents", "Docker context", "CLI", "PATH block",
                        "Also delete containers, images and volumes", "Keeps the Noodle data folder", "Cancel",
                        RenderHarness.env.paths.root.lastPathComponent])
    }

    @Test func incompleteInstalledAssistantKeepsDaemonRecoveryActions() async {
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: true)
        env.connection.phase = .down("Fixture stopped")
        env.connection.setupDone = true
        env.connection.setupCompleted = false
        let r = await RenderHarness.render(DaemonDownView(env: env, message: "Fixture stopped").frame(width: 760, height: 420).environment(\.productTone, WorkspaceStyle.containers), name: "setup-incomplete-daemon-recovery",
                                           size: CGSize(width: 760, height: 420), recognizeText: !bitmapOnly)
        expectShows(r, ["Start Noodle Containers", "Start", "Set Up Noodle"], minimumInk: 0.005)
    }

    @Test func selectedDataDeletionNamesFolderAndWarnsAboutEveryFile() async {
        let flow = UninstallFlow { _ in .init(code: 0, output: "Fixture only") }
        flow.deleteData = true
        let r = await RenderHarness.render(UninstallNoodleSheet(env: RenderHarness.env, flow: flow), name: "setup-uninstall-delete-data",
                                           size: CGSize(width: 560, height: 640), recognizeText: !bitmapOnly)
        expectShows(r, [RenderHarness.env.paths.root.lastPathComponent, "Permanently deletes everything in this folder",
                        "including any files you placed there"])
    }

    @Test func uninstallResultIsVisibleBeforeQuitting() async {
        let flow = UninstallFlow { _ in .init(code: 0, output: "Kept data in fixture-home") }
        await flow.uninstall()
        let r = await RenderHarness.render(UninstallNoodleSheet(env: RenderHarness.env, flow: flow), name: "setup-uninstall-result",
                                           size: CGSize(width: 560, height: 400), recognizeText: !bitmapOnly)
        expectShows(r, ["Noodle is uninstalled", "Kept data", "Quit Noodle"])
    }

    @Test func finaleShowsComposeProblemWithoutBlockingDone() async throws {
        let flow = try #require(SetupPreview.flow(named: "done"))
        flow.composeCheck = .failed("compose unavailable")
        let r = await RenderHarness.render(SetupSheetContent(flow: flow, close: { _ in }), name: "setup-compose-failed",
                                           size: CGSize(width: 760, height: 500), recognizeText: !bitmapOnly)
        expectShows(r, ["Hello from Noodle", "compose up", "Compose needs attention", "Done"])
    }

    @Test func emptyContainersAndSidebarOfferSetupUntilDone() async throws {
        _ = RenderHarness.env
        let env = AppEnvironment(service: DemoDocker(mode: .empty), demo: true)
        env.connection.phase = .up
        env.connection.setupDone = true
        env.connection.setupCompleted = false
        env.nav.route = .containers
        env.containers.apply([])
        let size = CGSize(width: 900, height: 460)
        let page = ContainersPage(env: env).frame(width: size.width, height: size.height)
        let unfinished = await RenderHarness.render(page, name: "setup-reentry-containers", size: size,
                                                    recognizeText: !bitmapOnly)
        expectShows(unfinished, ["Set Up Noodle"], minimumInk: 0.005)
        let card = await RenderHarness.render(VMStatusPager(env: env), name: "setup-reentry-sidebar", size: CGSize(width: 240, height: 320),
                                              recognizeText: !bitmapOnly)
        expectShows(card, ["Set Up Noodle"])
        env.connection.setupCompleted = true
        let finished = await RenderHarness.render(page, name: "setup-completed-containers", size: size,
                                                  recognizeText: !bitmapOnly)
        let quiet = await RenderHarness.render(VMStatusPager(env: env), name: "setup-completed-sidebar", size: CGSize(width: 240, height: 320),
                                               recognizeText: !bitmapOnly)
        #expect(finished.inkRatio > 0.005 && quiet.inkRatio > 0.02)
        #expect(try Data(contentsOf: unfinished.png) != Data(contentsOf: finished.png))
        #expect(try Data(contentsOf: card.png) != Data(contentsOf: quiet.png))
        if !bitmapOnly {
            #expect(!finished.contains("Set Up Noodle"))
            #expect(!quiet.contains("Set Up Noodle"))
        }
    }
}
