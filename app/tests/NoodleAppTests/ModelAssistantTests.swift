import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelAssistantTests {
    private func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("noodle-assistants-\(UUID().uuidString)")
    }

    @Test func assistantsRoundTripThroughDisk() throws {
        let dir = home()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelAssistantStore(home: dir)
        let added = store.add(name: "Editor")
        store.update(.init(id: added.id, name: "Editor", instructions: "Fix grammar.", modelID: "gemma4"))
        store.flush()
        let reloaded = ModelAssistantStore(home: dir)
        #expect(reloaded.all.map(\.name) == ["Default", "Editor"])
        #expect(reloaded.assistant(added.id).instructions == "Fix grammar.")
        #expect(reloaded.assistant(added.id).modelID == "gemma4")
        #expect(reloaded.assistant(nil).isBuiltIn)
        reloaded.delete(added.id)
        reloaded.flush()
        #expect(ModelAssistantStore(home: dir).custom.isEmpty)
    }

    @Test func chatsRecordAssistantAndSettingsAndOldChatsStillLoad() throws {
        let history = ModelChatHistory()
        let assistant = UUID()
        history.configure(assistantID: assistant, settings: .init(temperature: 0.2))
        history.appendUser("hi", modelID: "m")
        #expect(history.current?.assistantID == assistant)
        #expect(history.current?.settings?.temperature == 0.2)
        let old = Data(#"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"updatedAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(ModelConversation.self, from: old).assistantID == nil)
    }

    @Test func editResendDropsLaterMessages() async throws {
        let history = ModelChatHistory()
        let id = history.appendUser("one", modelID: "m")
        history.appendAssistant("a1", state: .completed, conversationID: id)
        history.appendUser("two", modelID: "m")
        history.appendAssistant("a2", state: .completed, conversationID: id)
        let second = try #require(history.current?.messages[2])
        let store = ModelsPageStore(demo: false, chatHistory: history, assistantStore: ModelAssistantStore())
        var sent: [[LocalModelChat.Message]] = []
        history.truncate(from: second.id, in: id)
        #expect(history.current?.messages.map(\.content) == ["one", "a1"])
        await store.runPrompt("two edited", modelID: "m") { messages, onText, _ in sent.append(messages); onText("ok") }
        #expect(history.current?.messages.map(\.content) == ["one", "a1", "two edited", "ok"])
        #expect(sent.count == 1 && sent[0].count == 3)
        history.deleteMessage(try #require(history.current?.messages[2]).id, in: id)
        #expect(history.current?.messages.map(\.content) == ["one", "a1"])
    }

    @Test func requestCarriesSystemPromptAndOnlyChangedSettings() async throws {
        let assistants = ModelAssistantStore()
        let assistant = assistants.add(name: "Pirate")
        assistants.update(.init(id: assistant.id, name: "Pirate", instructions: "Talk like a pirate."))
        let history = ModelChatHistory()
        history.configure(assistantID: assistant.id, settings: nil)
        let store = ModelsPageStore(demo: false, chatHistory: history, assistantStore: assistants)
        var sent: [LocalModelChat.Message] = []
        await store.runPrompt("hello", modelID: "m") { messages, onText, _ in sent = messages; onText("x") }
        #expect(sent.count == 2)
        let endpoint = LocalModelEndpoint(model: "m", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: "k")

        func body(_ settings: ModelChatSettings) throws -> [String: Any] {
            let request = try ModelPromptStream.request(messages: sent, to: endpoint, settings: settings)
            let data = try #require(request.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let plain = try body(.init())
        let messages = try #require(plain["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "Talk like a pirate.")
        #expect(plain["temperature"] == nil)
        #expect(plain["max_tokens"] == nil)
        #expect(plain["context_length"] == nil && plain["num_ctx"] == nil)

        let changed = try body(.init(temperature: 0.3, maxTokens: 900, contextLength: 4096))
        #expect(changed["temperature"] as? Double == 0.3)
        #expect(changed["max_tokens"] as? Int == 900)
        #expect(changed["context_length"] == nil && changed["num_ctx"] == nil)
        let onlyTemperature = try body(.init(temperature: 1.1))
        #expect(onlyTemperature["max_tokens"] == nil && onlyTemperature["temperature"] as? Double == 1.1)
        let huge = try body(.init(maxTokens: 9_999_999))
        #expect(huge["max_tokens"] as? Int == ModelChatSettings.maxTokensLimit)
    }

    @Test func deletingAUserMessageAlsoDeletesItsReply() throws {
        let history = ModelChatHistory()
        let id = history.appendUser("one", modelID: "m")
        history.appendAssistant("a1", state: .completed, conversationID: id)
        history.appendUser("two", modelID: "m")
        history.appendAssistant("a2", state: .completed, conversationID: id)
        history.deleteMessage(try #require(history.current?.messages[0]).id, in: id)
        #expect(history.current?.messages.map(\.content) == ["two", "a2"])
    }

    @Test func customBudgetTrimsOldestExchanges() throws {
        let history = ModelChatHistory()
        var id = UUID()
        for i in 0..<4 {
            id = history.appendUser("q\(i) " + String(repeating: "x", count: 400), modelID: "m")
            history.appendAssistant("a\(i)", state: .completed, conversationID: id)
        }
        let chat = try #require(history.current)
        #expect(chat.requestMessages(fitting: "next", budget: 600).count == 2)
        #expect(chat.requestMessages(fitting: "next").count == 8)
    }

    @Test func corruptAssistantsFileIsKeptAndBlocksSaving() throws {
        let dir = home()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("models/assistants.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = ModelAssistantStore(home: dir)
        #expect(store.persistenceIssue != nil)
        store.add(name: "Lost")
        store.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }

    @Test func deletedAssistantFallsBackToDefault() {
        let assistants = ModelAssistantStore()
        let gone = assistants.add(name: "Gone")
        assistants.delete(gone.id)
        #expect(assistants.assistant(gone.id).isBuiltIn)
    }

    @Test func resendThatIsNotAcceptedKeepsTheChat() async throws {
        let history = ModelChatHistory()
        let id = history.appendUser("one", modelID: "m")
        history.appendAssistant("a1", state: .completed, conversationID: id)
        let store = ModelsPageStore(demo: false, chatHistory: history, assistantStore: ModelAssistantStore())
        await store.resend(try #require(history.current?.messages[0]).id, text: "edited")  // server not running
        #expect(history.current?.messages.map(\.content) == ["one", "a1"])
    }
}
