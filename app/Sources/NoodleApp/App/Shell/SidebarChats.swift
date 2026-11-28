import SwiftUI

/// Chats listed under the Chat row, newest first, the way Compose lists its projects.
struct SidebarChats: View {
    let store: ModelsPageStore
    let tone: WorkspaceStyle.Tone
    /// The selected chat, or nil when the route is not Chat.
    let selectedID: UUID?
    @Binding var showsAll: Bool
    /// Rows before "Show all", so Create, Library, Apps and Connections stay in reach.
    var limit = Self.visibleLimit
    let open: (UUID) -> Void
    let delete: (UUID) -> Void

    static let visibleLimit = 5
    /// The limit for a short sidebar, where five chats would push Connections out of view at the minimum window.
    static let compactLimit = 3

    /// The chats the sidebar shows: the newest few plus the selected one, or all of them.
    static func visible(_ conversations: [ModelConversation], selected: UUID?, showsAll: Bool,
                        limit: Int = visibleLimit) -> [ModelConversation] {
        guard !showsAll, conversations.count > limit else { return conversations }
        let newest = Array(conversations.prefix(limit))
        guard let selected, !newest.contains(where: { $0.id == selected }),
              let chosen = conversations.first(where: { $0.id == selected }) else { return newest }
        return newest + [chosen]
    }

    var body: some View {
        let conversations = store.chat.conversations
        if conversations.isEmpty {
            Text("No chats yet").font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 36).listRowSeparator(.hidden)
        }
        ForEach(Self.visible(conversations, selected: store.chat.selectedID, showsAll: showsAll, limit: limit)) { conversation in
            let id = SidebarView.conversationID(conversation.id)
            SidebarRow(title: conversation.title, symbol: "bubble.left", tone: tone,
                       selected: selectedID == conversation.id, nested: true,
                       detail: conversation.updatedAt.formatted(.relative(presentation: .named))) {
                open(conversation.id)
            }
            .disabled(store.busy)
            .contextMenu {
                Button("Delete Conversation…", systemImage: "trash", role: .destructive) { delete(conversation.id) }
            }
            .accessibilityAction(named: "Delete conversation") { delete(conversation.id) }
            .id(id)
        }
        if conversations.count > limit {
            Button(showsAll ? "Show fewer" : "Show all \(conversations.count)") { Motion.animate { showsAll.toggle() } }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 36).listRowSeparator(.hidden)
        }
    }
}
