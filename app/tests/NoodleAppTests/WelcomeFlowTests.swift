import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite(.serialized) struct WelcomeFlowTests {
    private func scripted() -> (WelcomeFlow, ScriptedWelcomeSource) {
        let source = ScriptedWelcomeSource()
        source.step = .zero
        return (WelcomeFlow(source: source), source)
    }

    @Test func modelsAndContainersStartSelectedAndContinueNeedsOne() {
        let (flow, _) = scripted()
        #expect(flow.chosen == [.models, .containers] && flow.canContinue)
        flow.toggle(.models); flow.toggle(.containers)
        #expect(flow.chosen.isEmpty && !flow.canContinue)
        flow.next()
        #expect(flow.screen == .choose)
        flow.toggle(.runners)
        flow.next()
        #expect(flow.screen == .ready)
    }

    @Test func laterScreensShowOnlyChosenProductsInOrder() {
        let (flow, _) = scripted()
        flow.toggle(.runners); flow.toggle(.containers)
        #expect(flow.products == [.models, .runners])
        flow.next(); flow.next()
        #expect(flow.screen == .done && flow.products == [.models, .runners])
        flow.back()
        #expect(flow.screen == .ready)
    }

    @Test func scriptedColumnsFinishOnTheirButton() async throws {
        let (flow, source) = scripted()
        #expect(WelcomeProduct.allCases.allSatisfy { !flow.isDone($0) })
        flow.act(.containers); flow.act(.runners)
        #expect(flow.isDone(.containers) && flow.isDone(.runners) && flow.sheet == nil)
        flow.act(.models)
        try await SetupChecks.until("pretend download") { source.modelReady }
        #expect(flow.isDone(.models) && source.progress == nil)
    }

    @Test func liveColumnsReadTheAppsOwnState() {
        let env = AppEnvironment(service: DemoDocker(mode: .down), demo: true)
        env.connection.setupDone = false
        let fresh = LiveWelcomeSource(env: env, store: ModelsPageStore(demo: true, demoState: .firstRun))
        let flow = WelcomeFlow(source: fresh)
        #expect(!flow.isDone(.models) && fresh.starter != nil && !fresh.downloading)
        #expect(!flow.isDone(.containers) && !flow.isDone(.runners))
        // Connect and Add repo open the existing sheets.
        flow.act(.containers)
        #expect(flow.sheet == .setup)
        flow.act(.runners)
        #expect(flow.sheet == .addRepo)

        env.connection.setupDone = true
        env.connection.setupCompleted = true
        env.runnerRepos.reload(env: env)
        #expect(flow.isDone(.containers) && flow.isDone(.runners))
        // A chat model already on this Mac counts as ready at once, and names that model.
        let installed = LiveWelcomeSource(env: env, store: ModelsPageStore(demo: true, demoState: .installed))
        #expect(installed.modelReady && installed.starter?.installed == true)
    }

    @Test func showsOnceOnAFreshInstallOnly() throws {
        let name = "welcome-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WelcomeFlow.shouldShow(defaults: defaults, scripted: false, needsSetup: true, canChangeInstallation: true))
        #expect(!WelcomeFlow.shouldShow(defaults: defaults, scripted: true, needsSetup: true, canChangeInstallation: true))
        #expect(!WelcomeFlow.shouldShow(defaults: defaults, scripted: false, needsSetup: false, canChangeInstallation: true))
        #expect(!WelcomeFlow.shouldShow(defaults: defaults, scripted: false, needsSetup: true, canChangeInstallation: false))
        defaults.set(true, forKey: WelcomeFlow.shownKey)
        #expect(!WelcomeFlow.shouldShow(defaults: defaults, scripted: false, needsSetup: true, canChangeInstallation: true))
        defaults.removeObject(forKey: WelcomeFlow.shownKey)
        defaults.set(true, forKey: "setupDismissed")
        #expect(!WelcomeFlow.shouldShow(defaults: defaults, scripted: false, needsSetup: true, canChangeInstallation: true))
    }

    @Test(arguments: WelcomePreview.names) func previewStateRendersInBothAppearances(name: String) throws {
        for dark in [false, true] {
            let flow = try #require(WelcomePreview.flow(named: name))
            let rep = try #require(SetupChecks.render(WelcomeSheetContent(flow: flow, close: {}), dark: dark))
            #expect(SetupChecks.distinctColors(rep) > 4, "\(name) \(dark ? "dark" : "light") rendered blank")
        }
    }

    @Test func previewStatesMatchTheirNames() throws {
        #expect(WelcomePreview.flow(named: "nope") == nil)
        let downloading = try #require(WelcomePreview.flow(named: "ready-downloading"))
        #expect(downloading.screen == .ready && downloading.source.downloading && !downloading.isDone(.models))
        let done = try #require(WelcomePreview.flow(named: "ready-done"))
        #expect(WelcomeProduct.allCases.allSatisfy(done.isDone))
        #expect(try #require(WelcomePreview.flow(named: "done")).screen == .done)
    }
}
