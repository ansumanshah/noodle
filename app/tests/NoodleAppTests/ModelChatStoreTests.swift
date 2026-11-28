import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelChatStoreTests {
    @Test func followUpIncludesTheFirstExchangeAndFinalAnswerAppearsOnce() async throws {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        await store.runPrompt("My name is Ada.", modelID: "local") { messages, emit, metrics in
            let actual = try self.contents(messages)
            #expect(actual == ["My name is Ada."])
            #expect(store.chat.current?.messages.map(\.role) == [.user])
            emit("Hello ")
            emit("Ada.")
            metrics(.init(timeToFirstToken: 0.1, elapsed: 1, outputTokens: 3))
        }
        #expect(store.reply == "Hello Ada.")
        #expect(store.chat.current?.messages.map(\.content) == ["My name is Ada.", "Hello Ada."])
        #expect(store.generationMetrics?.outputTokens == 3)
        await store.runPrompt("What is my name?", modelID: "local") { messages, emit, _ in
            let actual = try self.contents(messages)
            #expect(actual == ["My name is Ada.", "Hello Ada.", "What is my name?"])
            emit("Ada.")
        }
        #expect(store.chat.current?.messages.count == 4)
        #expect(store.chat.current?.messages.last?.state == .completed)
        #expect(store.generationMetrics == nil, "Missing runner usage must not reuse the previous response metrics.")
        store.newChat()
        #expect(store.chat.current?.messages.isEmpty == true)
        #expect(store.reply.isEmpty)
        #expect(store.response.state == .idle)
    }

    @Test func cancellationKeepsPartialAnswerAndNextTurnOmitsInterruptedContext() async throws {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        let started = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); pending.continuation.finish() }
        let request = Task {
            await store.runPrompt("An interrupted question", modelID: "local") { _, emit, _ in
                emit("Partial answer")
                started.continuation.yield(())
                for await _ in pending.stream {}
                emit(" late output")
            }
        }
        var ready = started.stream.makeAsyncIterator()
        _ = await ready.next()
        let id = try #require(store.chat.selectedID)
        store.newChat()
        store.deleteConversation(id)
        #expect(store.chat.selectedID == id)
        #expect(store.chat.conversations.count == 1)
        store.cancelPrompt()
        await request.value
        #expect(store.response.state == .cancelled)
        #expect(store.chat.current?.messages.last?.content == "Partial answer")
        #expect(store.chat.current?.messages.last?.state == .cancelled)
        await store.runPrompt("Try again", modelID: "local") { messages, emit, _ in
            let actual = try self.contents(messages)
            #expect(actual == ["Try again"])
            emit("A complete answer")
        }
        #expect(store.chat.current?.messages.count == 4)
    }

    @Test func failedAndEmptyResponsesKeepUserMessagesWithoutInventingAssistantReplies() async throws {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        await store.runPrompt("Failed request", modelID: "local") { _, _, _ in throw ModelPromptError("Unavailable") }
        #expect(store.chat.current?.messages.map(\.role) == [.user])
        #expect(store.problem?.detail == "Unavailable")
        await store.runPrompt("Empty request", modelID: "local") { messages, _, _ in
            let actual = try self.contents(messages)
            #expect(actual == ["Empty request"])
        }
        #expect(store.response.state == .failed)
        #expect(store.chat.current?.messages.map(\.role) == [.user, .user])
        await store.runPrompt("Retry", modelID: "local") { messages, emit, _ in
            let actual = try self.contents(messages)
            #expect(actual == ["Retry"])
            emit("It works.")
        }
        #expect(store.problem == nil)
        #expect(store.chat.current?.messages.count == 4)
    }

    @Test func demosHaveMatchingConversationsAndReceivingHasOnlyALiveAssistant() {
        for state in [ModelsPageStore.DemoState.running, .receiving, .mlxRunning, .mlxReceiving] {
            let store = ModelsPageStore(demo: true, demoState: state)
            #expect(store.chat.current?.messages.first?.role == .user)
            #expect(store.chat.current?.modelID == store.status.model)
            if state == .receiving || state == .mlxReceiving {
                #expect(store.chat.current?.messages.count == 1)
            } else {
                #expect(store.chat.current?.messages.count == 2)
                #expect(store.chat.current?.messages.last?.content == store.reply)
            }
            #expect(store.generationMetrics == nil)
        }
    }

    private func contents(_ messages: [LocalModelChat.Message]) throws -> [String] {
        let data = try LocalModelChat.body(model: "local", messages: messages)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["messages"] as? [[String: String]]).compactMap { $0["content"] }
    }
}

@MainActor @Suite struct ModelServerWatchTests {
    private let url = URL(string: "http://127.0.0.1:11345/v1")

    private func ready(_ model: String, namedBaseURL: URL? = nil) -> LocalModelStatus {
        .init(phase: .ready, model: model, baseURL: url, namedBaseURL: namedBaseURL)
    }

    @Test func runnerThatExitsOnItsOwnRaisesARestartableProblem() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        await store.pollStatus { self.ready("qwen") }
        #expect(store.status.phase == .ready)
        #expect(store.problem == nil)
        await store.pollStatus { LocalModelStatus(phase: .stopped) }
        #expect(store.status.phase == .stopped)
        #expect(store.problem?.title == "The model server stopped")
        #expect(store.problem?.retry == .start("qwen"))
    }

    @Test func connectionsRouteFollowsTheRunnerWithoutManualRefresh() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        let named = URL(string: "http://qwen.noodle.test/v1")
        await store.pollStatus { self.ready("qwen", namedBaseURL: named) }
        #expect(store.status.namedBaseURL == named)
        await store.pollStatus { self.ready("qwen") }
        #expect(store.status.namedBaseURL == nil)
        #expect(store.problem == nil, "A lost route alone is not a crash.")
    }

    @Test func steadyStoppedStateRaisesNothing() async {
        let store = ModelsPageStore(demo: false, chatHistory: ModelChatHistory())
        await store.pollStatus { LocalModelStatus(phase: .stopped) }
        #expect(store.problem == nil)
    }
}

@Suite struct ModelChatPersistenceTests {
    @Test func writeReplacesAtomicallyAndLeavesNoTemporaryFiles() throws {
        let directory = scratchPath("chat")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat-history.json")
        try ModelChatPersistence.write(Data("one".utf8), to: file)
        try ModelChatPersistence.write(Data(String(repeating: "two", count: 100_000).utf8), to: file)
        #expect(try Data(contentsOf: file).count == 300_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["chat-history.json"])
    }
}
