import Foundation
import Observation

/// A name, a system prompt and an optional default model.
struct ModelAssistant: Identifiable, Codable, Equatable, Sendable {
    /// The built-in assistant. It has no instructions, is never stored and cannot be edited or deleted.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-00000000D0D0")!
    static var `default`: ModelAssistant { ModelAssistant(id: defaultID, name: String(localized: "Default")) }

    let id: UUID
    var name: String
    var instructions: String
    var modelID: String?

    init(id: UUID = UUID(), name: String, instructions: String = "", modelID: String? = nil) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.modelID = modelID
    }

    var isBuiltIn: Bool { id == Self.defaultID }
}

/// Per-chat sampling settings. A nil field is not sent, so the model and server defaults apply.
/// Context length is not an OpenAI request field: it sets how much history the app keeps in each request.
struct ModelChatSettings: Codable, Equatable, Sendable {
    var temperature: Double?
    var maxTokens: Int?
    var contextLength: Int?
    /// Nil means off: the request always says so explicitly.
    var thinking: Bool?

    static let maxTokensLimit = 131_072
    static let contextLengthLimit = 1_048_576

    var isDefault: Bool { self == ModelChatSettings() }
    var clamped: ModelChatSettings {
        .init(temperature: temperature.map { min(2, max(0, $0)) },
              maxTokens: maxTokens.map { min(Self.maxTokensLimit, max(1, $0)) },
              contextLength: contextLength.map { min(Self.contextLengthLimit, max(1, $0)) },
              thinking: thinking)
    }
    // shortcut: about four bytes of text per token, trimmed by the app only; use the model's tokenizer when it is exposed.
    var contextBudgetBytes: Int? { clamped.contextLength.map { max(256, $0) * 4 } }
}

/// Custom assistants, stored next to the saved chats (`models/assistants.json`) with the same private atomic writer.
@MainActor @Observable
final class ModelAssistantStore {
    private(set) var custom: [ModelAssistant] = []
    private(set) var persistenceIssue: String?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var writer: ModelChatWriter?

    var all: [ModelAssistant] { [.default] + custom }

    func assistant(_ id: UUID?) -> ModelAssistant { all.first { $0.id == id } ?? .default }

    /// A nil home is an isolated, in-memory store for previews and tests.
    init(home: URL? = nil) {
        file = home?.appendingPathComponent("models", isDirectory: true).appendingPathComponent("assistants.json")
        load()
        guard let file else { return }
        writer = ModelChatWriter(file: file) { [weak self] ok in
            Task { @MainActor in
                self?.persistenceIssue = ok ? nil : String(localized: "Assistants could not be saved. They are still available in this window.")
            }
        }
    }

    @discardableResult
    func add(name: String = "New assistant") -> ModelAssistant {
        let assistant = ModelAssistant(name: name)
        custom.append(assistant)
        save()
        return assistant
    }

    func update(_ assistant: ModelAssistant) {
        guard !assistant.isBuiltIn, let index = custom.firstIndex(where: { $0.id == assistant.id }) else { return }
        custom[index] = assistant
        save()
    }

    func delete(_ id: UUID) {
        custom.removeAll { $0.id == id }
        save()
    }

    /// Blocks until queued writes reach disk. Called by tests and when the sheet closes.
    func flush() { writer?.flush() }

    private func load() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try ModelChatPersistence.validate(file)
            let saved = try JSONDecoder().decode([ModelAssistant].self, from: Data(contentsOf: file))
            guard Set(saved.map(\.id)).count == saved.count else { throw CocoaError(.coderReadCorrupt) }
            custom = saved.filter { !$0.isBuiltIn }
        } catch {
            canSave = false
            persistenceIssue = String(localized: "Saved assistants could not be opened. Changes will stay in memory; the existing file has been kept.")
        }
    }

    private func save() {
        guard let writer, canSave else { return }
        do { writer.enqueue(try JSONEncoder().encode(custom)) } catch {
            persistenceIssue = String(localized: "Assistants could not be saved. They are still available in this window.")
        }
    }
}
