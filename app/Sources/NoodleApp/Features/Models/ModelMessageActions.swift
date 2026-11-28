import AppKit
import Observation
import SwiftUI

enum ModelMessageAction { case copy, regenerate, edit, delete }

@MainActor @Observable
final class ModelMessageActionsState {
    var visible = false
    var role: ModelChatMessage.Role = .user
    var canRegenerate = false
    @ObservationIgnored var perform: (ModelMessageAction) -> Void = { _ in }
}

/// Plain icons that appear under the message being hovered. No menus, so no disclosure arrows.
struct ModelMessageActionsBar: View {
    let state: ModelMessageActionsState

    var body: some View {
        HStack(spacing: 2) {
            button("Copy", "doc.on.doc", .copy)
            if state.role == .assistant, state.canRegenerate { button("Regenerate", "arrow.clockwise", .regenerate) }
            if state.role == .user { button("Edit and resend", "pencil", .edit) }
            button("Delete", "trash", .delete)
        }
        .padding(.horizontal, 4)
        .opacity(state.visible ? 1 : 0)
        .scaleEffect(state.visible ? 1 : 0.92, anchor: state.role == .user ? .topTrailing : .topLeading)
        .motion(Motion.snappy, value: state.visible)
        .allowsHitTesting(state.visible)
    }

    private func button(_ title: LocalizedStringKey, _ symbol: String, _ action: ModelMessageAction) -> some View {
        Button { state.perform(action) } label: {
            Image(systemName: symbol).font(.callout).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(title).accessibilityLabel(title)
    }
}

extension ModelsPageStore {
    /// Edit and resend, and regenerate: drops the message and everything after it, then sends `text` again.
    func resend(_ messageID: UUID, text: String) async {
        // Same acceptance rules as `test`, checked first so an early bail-out loses nothing.
        guard !busy, let id = chat.current?.id, demo || status.phase == .ready,
              text.utf8.count <= ModelChatHistory.maximumConversationBytes / 2 else { return }
        // Read the images before truncating deletes their files; they are saved again with the new message.
        let attachments = chat.attachmentSet(chat.current?.messages.first { $0.id == messageID }?.attachments ?? [])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        chat.truncate(from: messageID, in: id)
        await test(text, attachments: attachments)
    }

    func deleteMessage(_ messageID: UUID) {
        guard !busy, let id = chat.current?.id else { return }
        chat.deleteMessage(messageID, in: id)
    }

    /// The assistant's instructions go first as the system message and count against the context budget.
    func systemPromptAndBudget() -> (system: String, budget: Int) {
        let system = assistants.assistant(chat.current?.assistantID).instructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = chat.current?.settings?.contextBudgetBytes ?? ModelConversation.contextBudgetBytes
        return (system, budget - system.utf8.count)
    }
}
