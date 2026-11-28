import NoodleCore
import SwiftUI

/// Chat owns the entire available height; only the transcript scrolls.
struct ModelPromptPanel: View {
    let store: ModelsPageStore
    var selectedModel: LocalModel? = nil
    var openLibrary: () -> Void = {}
    var selectModel: (String) -> Void = { _ in }
    @State private var prompt = ""
    /// The user message being edited. Sending replaces it and drops everything after it.
    @State private var editingID: UUID?
    @State private var images: [ModelDraftImage] = []
    @State private var video: ModelDraftVideo?
    @State private var audio: ModelDraftAudio?

    private var composerState: ModelComposerState {
        guard store.status.phase == .ready else { return .unavailable }
        if store.activity == .prompt {
            if store.response.state == .cancelling { return .cancelling }
            return store.response.canCancel ? .responding : .busy
        }
        return store.busy ? .busy : .ready
    }

    private var recommended: LocalModel? { ModelLibraryPolicy.recommended(store.chatModels) }

    private var isEmpty: Bool {
        store.chat.current?.messages.isEmpty != false && store.reply.isEmpty && store.activity != .prompt
    }

    private var chatModelName: String? {
        guard let id = store.chat.current?.modelID ?? store.status.model ?? selectedModel?.id else { return nil }
        return store.models.first(where: { $0.id == id })?.name ?? id
    }

    // Conversations are listed in the sidebar under the Chat row.
    var body: some View {
        VStack(spacing: 0) {
            if isEmpty {
                ModelChatWelcomeView(ready: store.status.phase == .ready, selectedModel: selectedModel, openLibrary: openLibrary,
                                     recommended: recommended, hasInstalled: store.models.contains(where: \.installed),
                                     downloading: recommended.map { ModelLibraryPolicy.downloadingID(store.activity) == $0.id } ?? false,
                                     download: { if let id = recommended?.id { Task { await store.perform(.download(id)) } } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
            if store.memoryRefused {
                ModelMemoryNote(busy: store.busy, retry: { Task { await store.retryLastMessage() } }, dismiss: store.dismissMemoryRefusal)
                    .padding(.bottom, Space.s).transition(.opacity)
            }
            composer
        }
        // New Chat lives in the window toolbar, so the draft resets when the conversation changes.
        .onChange(of: store.chat.current?.id) { prompt = ""; editingID = nil; images = []; video = nil; audio = nil }
        .sheet(isPresented: Bindable(store).showsAssistants) { ModelAssistantsSheet(store: store) }
        .motion(Motion.standard, value: isEmpty)
        .motion(Motion.standard, value: store.memoryRefused)
    }

    @ViewBuilder private var transcript: some View {
        ModelChatTranscriptView(
            conversationID: store.chat.current?.id,
            messages: store.chat.current?.messages ?? [],
            liveText: store.activity == .prompt ? store.reply : "",
            fallbackText: store.chat.current?.messages.isEmpty != false ? store.reply : "",
            receiving: store.activity == .prompt, onAction: messageAction)
    }

    private func messageAction(_ action: ModelMessageAction, _ message: ModelChatMessage) {
        let messages = store.chat.current?.messages ?? []
        switch action {
        case .delete: store.deleteMessage(message.id)
        case .edit:
            prompt = message.content
            editingID = message.id
        case .regenerate:
            guard let index = messages.firstIndex(where: { $0.id == message.id }),
                  let user = messages[..<index].last(where: { $0.role == .user }) else { return }
            Task { await store.resend(user.id, text: user.content) }
        case .copy: break
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let issue = store.chat.persistenceIssue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Conversation history: \(issue)")
            }
            if editingID != nil {
                HStack {
                    Label("Editing your message. Sending replaces the replies after it.", systemImage: "pencil")
                    Spacer()
                    Button("Cancel") { editingID = nil; prompt = "" }.buttonStyle(.borderless).hoverFill()
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, Space.xs)
                .transition(.slide(from: .bottom))
            }
            ModelChatGenerationStatus(store: store)
            if store.status.phase != .ready, store.models.contains(where: \.installed) {
                Label(store.status.phase == .starting || isStarting
                      ? "Loading the model. Chat will be ready when the server is running."
                      : "Start a model with the Start button to chat.",
                      systemImage: store.status.phase == .starting || isStarting ? "hourglass" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
            ModelPromptComposer(text: $prompt, state: composerState, send: send, stop: store.cancelPrompt,
                                modelName: chatModelName, modelReady: store.status.phase == .ready,
                                images: $images, canAttach: store.acceptsImages,
                                video: $video, audio: $audio, canAttachVideo: store.acceptsVideo,
                                canAttachAudio: store.canAttachAudio, audioUnavailableReason: store.audioUnavailableReason)
        }
        .motion(Motion.snappy, value: editingID)
        .task(id: "\(store.status.model ?? "")-\(store.status.phase == .ready)") { await store.refreshImageSupport() }
        .task {
            // `--demo-attach-image=<file>` puts one image in the composer for headless captures.
            if store.demo, images.isEmpty, let path = DemoFlags.value("--demo-attach-image="),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = ModelDraftImage(data) { images = [image] }
        }
        .onChange(of: store.acceptsImages) { _, accepts in if !accepts { images = [] } }
        .onChange(of: store.acceptsVideo) { _, accepts in if !accepts { video = nil } }
        .onChange(of: store.canAttachAudio) { _, accepts in if !accepts { audio = nil } }
        .frame(maxWidth: ModelsChrome.readingWidth)
        .padding(.horizontal, Space.page).padding(.top, Space.m).padding(.bottom, Space.panel)
        .frame(maxWidth: .infinity)
    }

    private var isStarting: Bool {
        if case .command(.start) = store.activity { return true }
        return false
    }

    private func send() {
        let attached = ModelAttachmentSet(images: images.map(\.jpeg), video: video?.clip, audio: audio?.clip)
        guard composerState.canSend(prompt, hasAttachments: !attached.isEmpty) else { return }
        let submitted = prompt
        guard submitted.utf8.count <= ModelChatHistory.maximumConversationBytes / 2 else {
            // The store reports the validation error; preserve the draft for editing.
            Task { await store.test(submitted) }
            return
        }
        prompt = ""
        images = []
        video = nil
        audio = nil
        if let id = editingID {
            editingID = nil
            Task { await store.resend(id, text: submitted) }
        } else {
            Task { await store.test(submitted, attachments: attached) }
        }
    }
}
