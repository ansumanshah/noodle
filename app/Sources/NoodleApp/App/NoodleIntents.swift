import AppIntents
import Foundation
import NoodleCore

enum AskNoodleError: LocalizedError {
    case emptyPrompt, noModel, empty
    var errorDescription: String? {
        switch self {
        case .emptyPrompt: "Type a question to ask."
        case .noModel: "No model is running and none is installed. Open Noodle, go to Models and download one."
        case .empty: "The model returned no text."
        }
    }
}

/// Request building for the Ask Noodle intent, kept apart so it can be tested without a model.
enum AskNoodle {
    static func cleaned(_ prompt: String) throws -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AskNoodleError.emptyPrompt }
        return text
    }

    /// The running model's endpoint. Starts the picker's model, the way the Models page does, when none runs.
    @MainActor static func endpoint() async throws -> LocalModelEndpoint {
        let store = ModelsPage.sharedStore(demo: false)
        await store.refresh()
        if store.status.phase != .ready {
            guard let model = store.selectedModel, model.installed else { throw AskNoodleError.noModel }
            await store.perform(.start(model.id))
            guard store.status.phase == .ready else { throw AskNoodleError.noModel }
        }
        let result = await CLI.run(["model", "endpoint", "--json"], timeout: 10)
        return try JSONDecoder().decode(LocalModelEndpoint.self, from: Data(result.output.utf8))
    }
}

struct AskNoodleIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Noodle"
    static let description = IntentDescription("Ask the local model running in Noodle and get the answer as text.")
    static let openAppWhenRun = false

    @Parameter(title: "Prompt") var prompt: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try AskNoodle.cleaned(prompt)
        let endpoint = try await AskNoodle.endpoint()
        var answer = ""
        try await ModelPromptStream.send(text, to: endpoint) { answer = $0 }
        let result = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AskNoodleError.empty }
        return .result(value: result)
    }
}

struct OpenNoodleChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Noodle Chat"
    static let description = IntentDescription("Open Noodle's Models chat with the message box ready.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        QuickAsk.open()
        return .result()
    }
}

struct NoodleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskNoodleIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Noodle", systemImageName: "bubble.left")
        AppShortcut(intent: OpenNoodleChatIntent(), phrases: ["Open \(.applicationName) chat"],
                    shortTitle: "Open Noodle Chat", systemImageName: "bubble.left.and.text.bubble.right")
    }
}
