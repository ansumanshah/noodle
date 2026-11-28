import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelMemoryAndSpeedTests {
    @Test func onlyATransientShortfallCountsAsMemory() {
        let short = #"{"error":"Not enough GPU memory: 9.0 GB needed, 3.0 GB is available"}"#
        #expect(ModelMemoryRefusal.matches(status: 400, body: short))
        #expect(!ModelMemoryRefusal.matches(status: 400, body: "context too long"))
        #expect(!ModelMemoryRefusal.matches(status: 500, body: short))
        // A prompt that cannot fit even with the cache freed is a long conversation, not a busy Mac.
        #expect(!ModelMemoryRefusal.matches(status: 400, body: "GPU memory: prompt needs 9 GB, 3 GB is available even after freeing the prefix cache"))
        #expect(ModelMemoryRefusal.matchesMidStream("The model ran out of GPU memory while writing"))
        #expect(!ModelMemoryRefusal.matchesMidStream("The model ran out of memory."))
    }

    @Test func midStreamOutOfMemoryIsFriendlyAndNeverRetried() async throws {
        var decoder = ModelPromptDecoder()
        let event = "event: error\ndata: {\"error\":{\"message\":\"generation ran out of GPU memory\"}}\n\n"
        do {
            for byte in event.utf8 { _ = try decoder.consume(byte) }
            Issue.record("should have thrown")
        } catch let refusal as ModelMemoryRefusal { #expect(!refusal.transient) }
        var calls = 0
        try? await ModelMemoryRefusal.retrying(delay: .zero, onWait: { _ in }) { calls += 1; throw ModelMemoryRefusal(transient: false) }
        #expect(calls == 1)
    }

    @Test func refusalRetriesThreeTimesThenFails() async {
        var calls = 0
        var waits = 0
        do {
            try await ModelMemoryRefusal.retrying(delay: .zero, onWait: { if $0 { waits += 1 } }) {
                calls += 1
                throw ModelMemoryRefusal()
            }
            Issue.record("should have thrown")
        } catch { #expect(error is ModelMemoryRefusal) }
        #expect(calls == 4 && waits == 3)
        calls = 0
        try? await ModelMemoryRefusal.retrying(delay: .zero, onWait: { _ in }) {
            calls += 1
            if calls < 3 { throw ModelMemoryRefusal() }
        }
        #expect(calls == 3)
    }

    @Test func cancellingTheWaitStopsRetrying() async {
        var calls = 0
        let task = Task { @MainActor in
            try await ModelMemoryRefusal.retrying(delay: .seconds(30), onWait: { _ in }) { calls += 1; throw ModelMemoryRefusal() }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        #expect(calls == 1)
        if case .success = result { Issue.record("cancelled wait must throw") }
    }

    @Test func refusalShowsPlainProblemWithRetry() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory(), assistantStore: ModelAssistantStore())
        await store.runPrompt("hi", modelID: "m") { _, _, _ in throw ModelMemoryRefusal() }
        #expect(store.memoryRefused && store.problem == nil)
        store.dismissMemoryRefusal()
        #expect(!store.memoryRefused)
        // Another failure that happens to share the text is not a refusal.
        await store.runPrompt("hi", modelID: "m") { _, _, _ in throw ModelPromptError(ModelMemoryRefusal.title) }
        #expect(!store.memoryRefused && store.problem != nil)
    }

    @Test func tryAgainAfterAModelSwitchKeepsTheOldMessage() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory(), assistantStore: ModelAssistantStore())
        store.runCommand = { _, _ in CLI.Result(code: 1, output: "noodle: no runner") }
        await store.runPrompt("hello there", modelID: "a") { _, _, _ in throw ModelMemoryRefusal() }
        await store.pollStatus { LocalModelStatus(phase: .ready, model: "b") }
        await store.retryLastMessage()
        let texts = store.chat.conversations.flatMap(\.messages).filter { $0.role == .user }.map(\.content)
        #expect(texts.filter { $0 == "hello there" }.count == 2)
        #expect(store.chat.conversations.contains { $0.modelID == "a" && $0.messages.contains { $0.content == "hello there" } })
    }

    @Test func thinkingIsOffUnlessAsked() throws {
        let endpoint = LocalModelEndpoint(model: "m", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: "k")
        func thinking(_ settings: ModelChatSettings) throws -> Bool? {
            let data = try #require(ModelPromptStream.request(messages: [.init(role: .user, content: "x")], to: endpoint, settings: settings).httpBody)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["enable_thinking"] as? Bool
        }
        #expect(try thinking(.init()) == false)
        #expect(try thinking(.init(thinking: true)) == true)
        #expect(ModelChatSettings().isDefault)
    }

    @Test func cachedTokensAndSpeedLine() throws {
        var decoder = ModelPromptDecoder()
        let event = #"data: {"choices":[],"usage":{"completion_tokens":40,"prompt_tokens":20,"prompt_tokens_details":{"cached_tokens":12}}}"# + "\n\ndata: [DONE]\n\n"
        for byte in event.utf8 { _ = try decoder.consume(byte) }
        #expect(decoder.cachedTokens == 12 && decoder.promptTokens == 20)
        let metrics = ModelGenerationMetrics(timeToFirstToken: 0.3, elapsed: 2.3, outputTokens: 40, cachedTokens: 12, promptTokens: 20)
        #expect(metrics.speedLine == "15 words/s · 0.3 s to first word · from cache")
        // Reusing a sliver of the prompt is not worth saying.
        let sliver = ModelGenerationMetrics(timeToFirstToken: 0.3, elapsed: 2.3, outputTokens: 40, cachedTokens: 3, promptTokens: 20)
        #expect(sliver.speedLine?.contains("from cache") == false)
        #expect(ModelGenerationMetrics(elapsed: 1).speedLine == nil)
    }

    @Test func preferredModelIsQwen4BFrom16GB() {
        #expect(ModelLibraryPolicy.preferredModelID(totalMemory: 8 << 30) == "qwen3.5-2b")
        for gib: UInt64 in [16, 32] { #expect(ModelLibraryPolicy.preferredModelID(totalMemory: gib << 30) == "qwen3.5-4b") }
    }

    @Test func recommendsThePinnedModelElseSmallestThatFits() {
        let small = LocalModel(id: "small", name: "S", bytes: 1 << 30, installed: false, downloadable: true)
        let huge = LocalModel(id: "huge", name: "H", bytes: 100 << 30, installed: false, downloadable: true)
        let memory: UInt64 = 16 << 30
        #expect(ModelLibraryPolicy.recommended([huge, small], totalMemory: memory)?.id == "small")
        let pinned = LocalModel(id: ModelLibraryPolicy.preferredModelID(totalMemory: memory), name: "P", bytes: 2 << 30, installed: false, downloadable: true)
        #expect(ModelLibraryPolicy.recommended([small, pinned], totalMemory: memory)?.id == pinned.id)
        let installed = LocalModel(id: "have", name: "I", bytes: 1, installed: true, downloadable: true)
        #expect(ModelLibraryPolicy.recommended([installed, pinned], totalMemory: memory) == nil)
    }

    @Test func installedModelsNeverReadTooBig() {
        let big = LocalModel(id: "big", name: "B", bytes: 100 << 30, installed: false, downloadable: true)
        #expect(ModelLibraryPolicy.fit(big, totalMemory: 16 << 30) == .tooBig)
        let have = LocalModel(id: "big", name: "B", bytes: 100 << 30, installed: true, downloadable: true)
        #expect(ModelLibraryPolicy.fit(have, totalMemory: 16 << 30) == .tight)
    }

    @Test func claudeCodeGetsTheServerRootAndKey() {
        let url = URL(string: "http://127.0.0.1:11345/v1")!
        let claude = ModelConnectApp.claudeCode.snippet(baseURL: url, key: "K", model: "m")
        #expect(claude.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:11345\n") && claude.contains("=K"))
        #expect(claude.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL=m\n") && claude.contains("ANTHROPIC_SMALL_FAST_MODEL=m\n"))
        for app in ModelConnectApp.allCases where app != .claudeCode {
            #expect(app.snippet(baseURL: url, key: "K", model: "m").contains("http://127.0.0.1:11345/v1"))
        }
    }
}
