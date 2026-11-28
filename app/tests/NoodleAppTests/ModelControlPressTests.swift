import AppKit
import Foundation
import NoodleCore
import SwiftUI
import Testing
@testable import NoodleApp

/// The Cancel response and Try Again controls, driven through the same store calls their buttons make, with the
/// rendered page checked before and after. SwiftUI builds no accessibility tree for a window that is never shown,
/// so the native button presses are done live against `--demo-models=streaming` (see models-workspace.md).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ModelControlPressTests {
    // MARK: - Cancel response

    @Test func cancelResponseStopsAnEndlessStreamKeepsThePartialReplyAndTheNextPromptWorks() async throws {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        await store.pollStatus { LocalModelStatus(phase: .ready, model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1")) }
        #expect(store.status.phase == .ready)

        // The demo stream never ends by itself, so the only way out is cancelling.
        let request = Task {
            await store.runPrompt("Tell me a story about a lighthouse.", modelID: "local",
                                  operation: ModelsPageStore.demoStream(ModelsPageStore.demoStory, endless: true,
                                                                        interval: .milliseconds(5)))
        }
        try await waitUntil { store.response.state == .receiving && store.reply.count > 40 }
        let streaming = await RenderHarness.render(ModelsPage(store: store, inlineHeader: true),
                                                   name: "models-press-streaming", size: CGSize(width: 780, height: 520))
        #expect(streaming.contains("Cancel response"))
        #expect(store.response.state == .receiving, "Still streaming after the render: it does not end on its own.")

        store.cancelPrompt()   // the Cancel response button's action, and Esc in the composer
        await request.value
        #expect(store.response.state == .cancelled)
        #expect(store.activity == nil)
        let partial = try #require(store.chat.current?.messages.last)
        #expect(partial.role == .assistant)
        #expect(partial.state == .cancelled)
        #expect(!partial.content.isEmpty)
        #expect(partial.content == store.reply, "The saved partial reply is exactly what was on screen.")
        let frozen = store.reply
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.reply == frozen, "Nothing streams after the cancel.")
        let cancelled = await RenderHarness.render(ModelsPage(store: store, inlineHeader: true),
                                                   name: "models-press-cancelled", size: CGSize(width: 780, height: 520))
        #expect(!cancelled.contains("Cancel response"))

        await store.runPrompt("And a short one?", modelID: "local",
                              operation: ModelsPageStore.demoStream(ModelsPageStore.demoReply, endless: false,
                                                                    interval: .milliseconds(1)))
        #expect(store.response.state == .completed)
        #expect(store.chat.current?.messages.last?.state == .completed)
        #expect(store.chat.current?.messages.last?.content.trimmingCharacters(in: .whitespaces) == ModelsPageStore.demoReply)
        #expect(store.chat.current?.messages.count == 4)
    }

    // MARK: - Error card Try Again

    @Test func tryAgainOnTheErrorCardRerunsTheFailedStartAndClearsTheCard() async throws {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        let runner = FakeModelCommands(failingServes: 1)
        store.runCommand = { arguments, _ in await runner.run(arguments) }

        await store.perform(.start("local"))
        let problem = try #require(store.problem)
        #expect(problem.title == "Couldn’t start the model")
        #expect(problem.detail == "port 11345 is busy")
        #expect(await runner.serves == 1)
        // The page refreshes when it appears, and a successful refresh clears the card. Hold that refresh until the
        // render is done; the render ends the page's task, so the refresh then stops without touching the card.
        await runner.holdCatalog()
        let failed = await RenderHarness.render(ModelsPage(store: store, inlineHeader: true),
                                                name: "models-press-failed", size: CGSize(width: 780, height: 520))
        await runner.releaseCatalog()
        try await waitUntil { !store.busy }
        #expect(failed.contains("start the model"), "The card title, matched past the curly apostrophe OCR may read differently.")
        #expect(failed.contains("Try Again"))
        #expect(store.problem == problem)

        let retry = try #require(problem.retry)
        #expect(retry == .start("local"))
        await store.perform(retry)   // the Try Again button's action
        #expect(await runner.serves == 2)
        #expect(store.problem == nil)
        #expect(store.status.phase == .ready)
        #expect(store.status.model == "local")
        let cleared = await RenderHarness.render(ModelsPage(store: store, inlineHeader: true),
                                                 name: "models-press-retried", size: CGSize(width: 780, height: 520))
        #expect(!cleared.contains("Try Again"), "The card clears once the retry succeeds.")
        #expect(!cleared.contains("start the model"))
    }

}

/// A `noodle model …` stand-in: `serve` fails the first `failingServes` times, then the model reports ready.
private actor FakeModelCommands {
    private var failuresLeft: Int
    private(set) var serves = 0
    private var running = false
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(failingServes: Int) { failuresLeft = failingServes }

    func holdCatalog() { holding = true }

    func releaseCatalog() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    func run(_ arguments: [String]) async -> CLI.Result {
        switch arguments.dropFirst().first {
        case "serve":
            serves += 1
            if failuresLeft > 0 {
                failuresLeft -= 1
                return CLI.Result(code: 1, output: "noodle: port 11345 is busy")
            }
            running = true
            return CLI.Result(code: 0, output: "")
        case "catalog":
            if holding { await withCheckedContinuation { held.append($0) } }
            let models = [LocalModel(id: "local", name: "Local Test", bytes: 1_000, installed: true, downloadable: false)]
            return CLI.Result(code: 0, output: Self.json(models))
        case "status":
            let status = running
                ? LocalModelStatus(phase: .ready, model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1"))
                : LocalModelStatus(phase: .stopped)
            return CLI.Result(code: 0, output: Self.json(status))
        default:
            return CLI.Result(code: 2, output: "noodle: unexpected \(arguments)")
        }
    }

    private static func json(_ value: some Encodable) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
