import AppKit
import Foundation
import NoodleCore
import Observation

struct ModelChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum State: String, Codable, Sendable { case completed, cancelled, failed, truncated }

    let id: UUID
    let role: Role
    let content: String
    let state: State?
    /// File names under `<home>/models/chat-attachments/`; nil for text-only messages and chats saved before images.
    let attachments: [String]?

    init(id: UUID = UUID(), role: Role, content: String, state: State? = nil, attachments: [String]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.state = state
        self.attachments = attachments?.isEmpty == false ? attachments : nil
    }
}

struct ModelConversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let modelID: String?
    let messages: [ModelChatMessage]
    let updatedAt: Date
    /// Optional so chats saved before assistants existed still load.
    var assistantID: UUID?
    var settings: ModelChatSettings?

    init(id: UUID = UUID(), title: String = "New chat", modelID: String? = nil,
         messages: [ModelChatMessage] = [], updatedAt: Date = Date(),
         assistantID: UUID? = nil, settings: ModelChatSettings? = nil) {
        self.assistantID = assistantID
        self.settings = settings
        self.id = id
        self.title = title
        self.modelID = modelID
        self.messages = messages
        self.updatedAt = updatedAt
    }

    /// Interrupted answers remain visible, but only complete exchanges become model context.
    /// Failed requests without an answer therefore cannot introduce consecutive user roles on retry.
    /// The client keeps a conservative prompt budget while the engine sizes its context automatically. Oldest exchanges are dropped first so a long chat keeps working.
    static let contextBudgetBytes = 9_000

    func requestMessages(fitting prompt: String, budget: Int = contextBudgetBytes) -> [LocalModelChat.Message] {
        var exchanges = completedExchanges
        var total = prompt.utf8.count + exchanges.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count }
        while total > budget, !exchanges.isEmpty {
            let dropped = exchanges.removeFirst()
            total -= dropped.0.utf8.count + dropped.1.utf8.count
        }
        return exchanges.flatMap { [LocalModelChat.Message(role: .user, content: $0.0), .init(role: .assistant, content: $0.1)] }
    }

    var requestMessages: [LocalModelChat.Message] {
        completedExchanges.flatMap { [LocalModelChat.Message(role: .user, content: $0.0), .init(role: .assistant, content: $0.1)] }
    }

    private var completedExchanges: [(String, String)] {
        var result: [(String, String)] = []
        var pending: ModelChatMessage?
        for message in messages {
            if message.role == .user {
                pending = message.state == .truncated ? nil : message
            } else {
                if let user = pending, message.state == .completed,
                   !user.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append((user.content, message.content))
                }
                pending = nil
            }
        }
        return result
    }
}

@MainActor @Observable
final class ModelChatHistory {
    static let maximumConversations = 30
    static let maximumMessages = 100
    static let maximumConversationBytes = 262_144

    private(set) var conversations: [ModelConversation] = []
    private(set) var selectedID: UUID?
    private(set) var persistenceIssue: String?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored let home: URL?
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var writer: ModelChatWriter?
    @ObservationIgnored private var quitObserver: ObserverToken?

    var current: ModelConversation? { conversations.first { $0.id == selectedID } }

    /// A nil home is an isolated, in-memory history for previews and tests.
    init(home: URL? = nil) {
        self.home = home
        file = home?.appendingPathComponent("models", isDirectory: true).appendingPathComponent("chat-history.json")
        load()
        guard let file else { return }
        writer = ModelChatWriter(file: file) { [weak self] ok in
            Task { @MainActor in self?.writeFinished(ok) }
        }
        // The app delegate has no quit hook for chats, so flush the last pending write on termination.
        quitObserver = ObserverToken(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
    }

    /// A new chat keeps the current chat's assistant and settings.
    func beginNewConversation() {
        let draft = ModelConversation(assistantID: current?.assistantID, settings: current?.settings)
        conversations.removeAll { $0.messages.isEmpty }
        conversations.insert(draft, at: 0)
        selectedID = draft.id
        trimConversations()
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func delete(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        let before = attachmentNames
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
        save()
        purgeUnreferenced(before)
    }

    private var attachmentNames: Set<String> {
        Set(conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] })
    }

    /// Deletes attachment files no remaining message points at (deleted chat or message, trimmed history).
    private func purgeUnreferenced(_ candidates: Set<String>) {
        guard let home else { return }
        ModelChatAttachments.remove(candidates.subtracting(attachmentNames), home: home)
    }

    /// Stores downscaled JPEGs for a message about to be appended. Without a home (previews, tests) nothing is kept.
    func saveAttachments(_ images: [Data]) -> [String] {
        guard let home else { return [] }
        return images.prefix(ModelChatAttachments.maximumPerMessage).compactMap { try? ModelChatAttachments.save($0, home: home) }
    }

    /// Images, then the video and audio of one message, each saved as its own file.
    func saveAttachments(_ set: ModelAttachmentSet) -> [String] {
        guard let home else { return [] }
        var names = saveAttachments(set.images)
        if let video = set.video, let data = try? JSONEncoder().encode(video), let name = try? ModelChatAttachments.save(data, extension: "vid", home: home) { names.append(name) }
        if let audio = set.audio, let name = try? ModelChatAttachments.save(audio.wav, extension: "wav", home: home) { names.append(name) }
        return names
    }

    func attachmentSet(_ names: [String]) -> ModelAttachmentSet {
        guard let home else { return .init() }
        var set = ModelAttachmentSet()
        for name in names {
            guard let data = ModelChatAttachments.load(name, home: home) else { continue }
            switch name.split(separator: ".").last {
            case "jpg": set.images.append(data)
            case "vid": set.video = try? JSONDecoder().decode(ModelVideoClip.self, from: data)
            default: set.audio = ModelAudioClip(wav: data)
            }
        }
        return set
    }

    func attachmentData(_ names: [String]) -> [Data] {
        guard let home else { return [] }
        return names.compactMap { ModelChatAttachments.load($0, home: home) }
    }

    @discardableResult
    func appendUser(_ content: String, modelID: String?, attachments: [String] = []) -> UUID {
        if current == nil || (current?.modelID != nil && current?.modelID != modelID) {
            beginNewConversation()
        }
        let conversation = current!
        let title = conversation.messages.isEmpty
            ? String(content.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(64))
            : conversation.title
        replace(conversation, title: title.isEmpty ? "New chat" : title, modelID: modelID,
                messages: conversation.messages + [.init(role: .user, content: content, attachments: attachments)])
        return conversation.id
    }

    func appendAssistant(_ content: String, state: ModelChatMessage.State, conversationID: UUID) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conversation = conversations.first(where: { $0.id == conversationID }),
              conversation.messages.last?.role == .user else { return }
        replace(conversation, title: conversation.title, modelID: conversation.modelID,
                messages: conversation.messages + [.init(role: .assistant, content: content, state: state)])
    }

    /// Records the chat's assistant and settings, creating a draft chat when none is open.
    func configure(assistantID: UUID?, settings: ModelChatSettings?) {
        if current == nil { beginNewConversation() }
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[index].assistantID = assistantID
        conversations[index].settings = settings?.isDefault == true ? nil : settings
        save()
    }

    /// Edit and resend: removes the message and everything after it.
    func truncate(from messageID: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        replace(conversation, title: conversation.title, modelID: conversation.modelID,
                messages: Array(conversation.messages[..<index]))
    }

    /// Deleting a question also removes its answer, which would otherwise be left without context.
    func deleteMessage(_ messageID: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        var messages = conversation.messages
        let removesReply = messages[index].role == .user && messages.indices.contains(index + 1)
            && messages[index + 1].role == .assistant
        messages.removeSubrange(index...(removesReply ? index + 1 : index))
        replace(conversation, title: conversation.title, modelID: conversation.modelID, messages: messages)
    }

    private func replace(_ conversation: ModelConversation, title: String, modelID: String?, messages: [ModelChatMessage]) {
        let updated = ModelConversation(id: conversation.id, title: title, modelID: modelID,
                                        messages: Self.bounded(messages), updatedAt: Date(),
                                        assistantID: conversation.assistantID, settings: conversation.settings)
        let before = attachmentNames
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(updated, at: 0)
        trimConversations()
        save()
        purgeUnreferenced(before)
    }

    private func trimConversations() {
        var savedCount = 0
        var hasDraft = false
        conversations = conversations.filter { conversation in
            if conversation.messages.isEmpty {
                guard !hasDraft else { return false }
                hasDraft = true
                return true
            }
            savedCount += 1
            return savedCount <= Self.maximumConversations
        }
    }

    private static func bounded(_ messages: [ModelChatMessage]) -> [ModelChatMessage] {
        var bounded = Array(messages.suffix(maximumMessages))
        // Shorten only an oversized last message, leaving half the budget for earlier messages.
        if let last = bounded.last, last.content.utf8.count > maximumConversationBytes {
            let marker = "\n\n[Saved message shortened to fit chat history.]"
            var prefix = Array(last.content.utf8.prefix(maximumConversationBytes / 2 - marker.utf8.count))
            var text = String(bytes: prefix, encoding: .utf8)
            // A byte prefix can end inside a scalar. Remove only the incomplete scalar's bytes.
            while text == nil {
                prefix.removeLast()
                text = String(bytes: prefix, encoding: .utf8)
            }
            bounded[bounded.count - 1] = .init(id: last.id, role: last.role, content: text! + marker, state: .truncated, attachments: last.attachments)
        }
        var bytes = bounded.reduce(0) { $0 + $1.content.utf8.count }
        while bounded.count > 1 && bytes > maximumConversationBytes {
            bytes -= bounded.removeFirst().content.utf8.count
        }
        // Eviction can leave an orphan assistant; never expose it as a complete exchange.
        while bounded.count > 1 && bounded.first?.role == .assistant { bounded.removeFirst() }
        return bounded
    }

    private func load() {
        guard let file else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return }
        do {
            try ModelChatPersistence.validate(file)
            let attributes = try manager.attributesOfItem(atPath: file.path)
            // JSON escaping can use six bytes per byte of control-character content.
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 67_108_864 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let saved = try JSONDecoder().decode([ModelConversation].self, from: Data(contentsOf: file))
            guard Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.coderReadCorrupt) }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            conversations = saved.filter { !$0.messages.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.maximumConversations).map {
                ModelConversation(id: $0.id, title: String($0.title.prefix(64)), modelID: $0.modelID,
                                  messages: Self.bounded($0.messages), updatedAt: $0.updatedAt,
                                  assistantID: $0.assistantID, settings: $0.settings)
            }
            selectedID = conversations.first?.id
        } catch {
            canSave = false
            persistenceIssue = String(localized: "Saved chats could not be opened. New chats will stay in memory; the existing file has been kept.")
        }
    }

    /// Encodes on the MainActor; the write happens on a background writer that keeps only the newest data.
    private func save() {
        guard let writer, canSave else { return }
        do {
            writer.enqueue(try JSONEncoder().encode(conversations.filter { !$0.messages.isEmpty }))
        } catch {
            persistenceIssue = String(localized: "The chat could not be saved. It is still available in this window.")
        }
    }

    /// Blocks until every queued write has reached disk. Called on app quit and by tests.
    func flush() { writer?.flush() }

    private func writeFinished(_ succeeded: Bool) {
        persistenceIssue = succeeded ? nil : String(localized: "The chat could not be saved. It is still available in this window.")
    }
}
/// Removes a notification observer when its owner goes away.
private final class ObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
