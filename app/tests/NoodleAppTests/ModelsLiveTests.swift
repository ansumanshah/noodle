import Foundation
import Testing
@testable import NoodleApp

@MainActor struct ModelsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOODLE_MODELS_APP_CLI"] != nil))
    func manageAndPrompt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let expectedCLI = URL(fileURLWithPath: try #require(environment["NOODLE_MODELS_APP_CLI"]))
        let cli = try #require(CLI.locate())
        try #require(cli.resolvingSymlinksInPath() == expectedCLI.resolvingSymlinksInPath())
        let home = URL(fileURLWithPath: try #require(environment["NOODLE_HOME"])).resolvingSymlinksInPath()
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        try #require(home.deletingLastPathComponent().path == tempRoot.path)
        try #require(home.lastPathComponent.hasPrefix("noodle-models-app."))
        let modelID = environment["NOODLE_MODELS_APP_MODEL"] ?? "gemma4"

        let store = ModelsPageStore(demo: false)
        await store.refresh()
        try #require(store.status.phase == .stopped)
        try #require(store.models.contains { $0.id == modelID && $0.downloadable })

        await store.perform(.download(modelID))
        try #require(store.problem == nil)
        try #require(store.models.contains { $0.id == modelID && $0.installed })

        await store.perform(.start(modelID))
        try #require(store.problem == nil)
        try #require(store.status.phase == .ready)
        #expect(store.status.model == modelID)
        let keyLength = await store.connectionKey()?.count
        #expect(keyLength == 64)

        await store.test("Say hello in one sentence.")
        #expect(store.problem == nil)
        #expect(!store.reply.isEmpty)
        #expect(store.response.state == .completed)
        #expect(store.activity == nil)

        let pending = Task { await store.test("Write a numbered list from 1 to 2000, with a short sentence for every number. Keep writing until the entire list is complete.") }
        defer { pending.cancel() }
        try await waitUntil { store.response.state == .receiving }
        try #require(store.response.state == .receiving)
        let partial = store.reply
        store.cancelPrompt()
        await pending.value
        #expect(store.response.state == .cancelled)
        #expect(store.reply.hasPrefix(partial))
        #expect(store.activity == nil)
        await store.refresh()
        try #require(store.status.phase == .ready)
        await store.test("Say hello again in one short sentence.")
        #expect(store.problem == nil)
        #expect(store.response.state == .completed)

        await store.perform(.stop)
        try #require(store.problem == nil)
        try #require(store.status.phase == .stopped)
        await store.perform(.remove(modelID))
        #expect(store.problem == nil)
        #expect(store.models.contains { $0.id == modelID && !$0.installed })

        await store.perform(.start(modelID))
        let problem = try #require(store.problem)
        #expect(problem.title == "Couldn’t start the model")
        #expect(problem.detail.contains("not installed"))
        #expect(problem.retry == .start(modelID))
        #expect(store.status.phase == .stopped)
        store.dismissProblem()
        #expect(store.problem == nil)
    }
}
