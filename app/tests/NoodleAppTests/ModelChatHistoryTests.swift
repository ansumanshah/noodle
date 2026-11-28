import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelChatHistoryTests {
    @Test func completeExchangesAreTheOnlyContextAndSnapshotsAreValues() throws {
        let history = ModelChatHistory()
        let id = history.appendUser("My name is Ada.", modelID: "local")
        let snapshot = try #require(history.current)
        history.appendAssistant("Hello Ada.", state: .completed, conversationID: id)
        history.appendUser("An unanswered request", modelID: "local")
        history.appendUser("A cancelled request", modelID: "local")
        history.appendAssistant("partial", state: .cancelled, conversationID: id)
        history.appendUser("A failed request", modelID: "local")
        history.appendAssistant("incomplete", state: .failed, conversationID: id)
        history.appendUser("What is my name?", modelID: "local")
        #expect(snapshot.messages.count == 1)
        let messages = try requestMessages(history.current!.requestMessages)
        #expect(messages.map { $0["role"] } == ["user", "assistant"])
        #expect(messages.map { $0["content"] } == ["My name is Ada.", "Hello Ada."])
        #expect(history.current?.messages.count == 8)
    }

    @Test func longChatsDropOldestExchangesToFitTheRunnerContext() throws {
        let history = ModelChatHistory()
        let filler = String(repeating: "x", count: 3_000)
        var id = UUID()
        for i in 0..<6 {
            id = history.appendUser("q\(i) " + filler, modelID: "local")
            history.appendAssistant("a\(i) " + filler, state: .completed, conversationID: id)
        }
        let chat = try #require(history.current)
        let fitted = try requestMessages(chat.requestMessages(fitting: "next"))
        let contents = fitted.compactMap { $0["content"] }
        let bytes = contents.reduce(4) { $0 + $1.utf8.count }
        #expect(bytes <= ModelConversation.contextBudgetBytes)
        #expect(fitted.count % 2 == 0 && !fitted.isEmpty)
        #expect(contents.last?.hasPrefix("a5") == true)
        #expect(contents.first?.hasPrefix("q0") == false)
    }

    @Test func selectionDeletionAndModelChangeKeepChatsSeparate() throws {
        let history = ModelChatHistory()
        let first = history.appendUser("First model", modelID: "one")
        history.appendAssistant("First answer", state: .completed, conversationID: first)
        let second = history.appendUser("Second model", modelID: "two")
        #expect(first != second)
        #expect(history.current?.modelID == "two")
        #expect(history.current?.requestMessages.isEmpty == true)
        history.select(first)
        #expect(history.current?.messages.count == 2)
        history.delete(first)
        #expect(history.selectedID == second)
        #expect(history.conversations.count == 1)
        history.select(UUID())
        #expect(history.selectedID == second)
    }

    @Test func historyRoundTripsPrivatelyWithoutEndpointCredentials() throws {
        let home = scratchPath("chat")
        defer { try? FileManager.default.removeItem(at: home) }
        let history = ModelChatHistory(home: home)
        let id = history.appendUser("Remember my name.", modelID: "local")
        history.appendAssistant("I will.", state: .completed, conversationID: id)
        history.flush()
        let restored = ModelChatHistory(home: home)
        #expect(restored.conversations == history.conversations)
        #expect(restored.selectedID == id)
        let directory = home.appendingPathComponent("models")
        let file = directory.appendingPathComponent("chat-history.json")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("apiKey"))
        #expect(!saved.contains("Bearer"))
        restored.delete(id)
        restored.flush()
        #expect(ModelChatHistory(home: home).conversations.isEmpty)
    }

    @Test func corruptHistoryIsPreservedWhileNewChatWorksInMemory() throws {
        let home = scratchPath("chat")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("chat-history.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: file)
        let history = ModelChatHistory(home: home)
        #expect(history.persistenceIssue != nil)
        let id = history.appendUser("A new request", modelID: "local")
        history.appendAssistant("A new answer", state: .completed, conversationID: id)
        #expect(history.current?.messages.count == 2)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func boundedHistoryEvictsOldEntriesAndMarksOversizedMessages() throws {
        let history = ModelChatHistory()
        for index in 0..<(ModelChatHistory.maximumConversations + 3) {
            history.beginNewConversation()
            history.appendUser("Chat \(index)", modelID: "local")
        }
        #expect(history.conversations.count == ModelChatHistory.maximumConversations)
        #expect(history.conversations.last?.title == "Chat 3")
        let id = try #require(history.selectedID)
        for index in 0..<70 {
            history.appendAssistant("Answer \(index)", state: .completed, conversationID: id)
            history.appendUser("Question \(index)", modelID: "local")
        }
        #expect(history.current!.messages.count <= ModelChatHistory.maximumMessages)
        history.appendAssistant(String(repeating: "🐱", count: ModelChatHistory.maximumConversationBytes),
                                state: .completed, conversationID: id)
        let saved = try #require(history.current?.messages.last)
        #expect(saved.content.utf8.count <= ModelChatHistory.maximumConversationBytes)
        #expect(saved.content.contains("Saved message shortened"))
        #expect(saved.state == .truncated)
        #expect(try requestMessages(history.current!.requestMessages).contains { $0["content"]?.contains("Saved message shortened") == true } == false)
    }

    @Test func oversizedLastMessageKeepsEarlierMessages() throws {
        let history = ModelChatHistory()
        let id = history.appendUser("Earlier question", modelID: "local")
        history.appendAssistant("Earlier answer", state: .completed, conversationID: id)
        history.appendUser(String(repeating: "a", count: ModelChatHistory.maximumConversationBytes * 2), modelID: "local")
        let messages = try #require(history.current?.messages)
        #expect(messages.count == 3)
        #expect(messages.map(\.content).prefix(2) == ["Earlier question", "Earlier answer"])
        #expect(messages[2].state == .truncated)
        #expect(messages.reduce(0) { $0 + $1.content.utf8.count } <= ModelChatHistory.maximumConversationBytes)
    }

    @Test func emptyDraftsPreserveTheFullSavedHistoryUntilTheFirstMessage() throws {
        let home = scratchPath("chat")
        defer { try? FileManager.default.removeItem(at: home) }
        let history = ModelChatHistory(home: home)
        for index in 0..<ModelChatHistory.maximumConversations {
            history.beginNewConversation()
            history.appendUser("Saved chat \(index)", modelID: "local")
        }
        let savedIDs = Set(history.conversations.map(\.id))
        let oldest = try #require(history.conversations.last?.id)
        history.beginNewConversation()
        history.beginNewConversation()
        #expect(history.conversations.filter { $0.messages.isEmpty }.count == 1)
        #expect(Set(history.conversations.filter { !$0.messages.isEmpty }.map(\.id)) == savedIDs)
        let draft = try #require(history.selectedID)
        history.delete(draft)
        history.flush()
        #expect(Set(ModelChatHistory(home: home).conversations.map(\.id)) == savedIDs)
        history.beginNewConversation()
        history.appendUser("A new saved chat", modelID: "local")
        #expect(history.conversations.count == ModelChatHistory.maximumConversations)
        #expect(!history.conversations.contains { $0.id == oldest })
    }

    @Test func oversizedSavedMessagesEndAtAValidUnicodeScalarBoundary() throws {
        for prefix in ["", "a", "ab", "abc"] {
            let history = ModelChatHistory()
            let id = history.appendUser("Question", modelID: "local")
            let content = prefix + String(repeating: "🐱", count: ModelChatHistory.maximumConversationBytes)
            history.appendAssistant(content, state: .completed, conversationID: id)
            let saved = try #require(history.current?.messages.last)
            let markerRange = try #require(saved.content.range(of: "\n\n[Saved message shortened"))
            let savedPrefix = String(saved.content[..<markerRange.lowerBound])
            #expect(content.hasPrefix(savedPrefix))
            #expect(!saved.content.contains("\u{FFFD}"))
            #expect(saved.content.utf8.count <= ModelChatHistory.maximumConversationBytes)
            #expect(saved.state == .truncated)
        }
    }

    @Test func existingHistorySymlinkIsNotFollowedOrOverwritten() throws {
        let home = scratchPath("chat")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("original.json")
        let original = Data("[]".utf8)
        try original.write(to: target)
        let file = directory.appendingPathComponent("chat-history.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let history = ModelChatHistory(home: home)
        #expect(history.persistenceIssue != nil)
        history.appendUser("New chat", modelID: "local")
        #expect(try Data(contentsOf: target) == original)
        #expect(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    private func requestMessages(_ messages: [LocalModelChat.Message]) throws -> [[String: String]] {
        let endpoint = LocalModelEndpoint(model: "local", baseURL: URL(string: "http://127.0.0.1:11345/v1")!, apiKey: "fixture")
        let request = try ModelPromptStream.request(messages: messages, to: endpoint)
        let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        return try #require(object["messages"] as? [[String: String]])
    }
}
