// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
import SwiftUI
import UniformTypeIdentifiers

enum ModelComposerState: CaseIterable {
    case unavailable, ready, responding, cancelling, busy

    var isEditable: Bool { self == .ready || self == .responding }
    var canStop: Bool { self == .responding }
    var showsStop: Bool { self == .responding || self == .cancelling }

    func canSend(_ text: String, hasAttachments: Bool = false) -> Bool {
        self == .ready && (hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// One rounded container, two rows: the input with the column's full width, its controls beneath and inside
/// the same border. Round send and stop controls.
@MainActor
struct ModelPromptComposer: View {
    @Binding var text: String
    let state: ModelComposerState
    let send: () -> Void
    let stop: () -> Void
    var modelName: String? = nil
    var modelReady = false
    /// Images waiting to be sent, at most `ModelChatAttachments.maximumPerMessage`.
    @Binding var images: [ModelDraftImage]
    /// Whether the running model reads images; when false the attach button is disabled and paste/drop are plain.
    var canAttach = false
    /// One video and one audio clip per message; each gated like images.
    @Binding var video: ModelDraftVideo?
    @Binding var audio: ModelDraftAudio?
    var canAttachVideo = false
    var canAttachAudio = false
    /// Why audio can't be attached, shown as the button's tooltip when nothing else can be.
    var audioUnavailableReason = "The selected model can’t hear audio"
    @State private var attachProblem: String?
    @State private var choosingImages = false
    @State private var measuredHeight: CGFloat = 36
    @State private var hasMarkedText = false
    @Environment(\.colorScheme) private var colorScheme

    private var hasAttachments: Bool { !images.isEmpty || video != nil || audio != nil }
    private var canSend: Bool { state.canSend(text, hasAttachments: hasAttachments) && !hasMarkedText }
    private var canAttachAny: Bool { canAttach || canAttachVideo || canAttachAudio }
    private var attachTypes: [UTType] { (canAttach ? [.image] : []) + (canAttachVideo ? [.movie] : []) + (canAttachAudio ? [.audio] : []) }

    var body: some View {
        card
            .motion(Motion.snappy, value: images.count)
            // Drops land in the text editor (ModelComposerTextView); a card-level drop target blanked offscreen renders.
            .fileImporter(isPresented: $choosingImages, allowedContentTypes: attachTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                addFiles(urls)
            }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            ModelPromptEditor(
                text: $text, measuredHeight: $measuredHeight, state: state,
                onMarkedTextChanged: { hasMarkedText = $0 }, onSend: send, onCancel: stop,
                onImages: imageHandler, onMedia: mediaHandler, hasAttachments: hasAttachments)
                .frame(height: measuredHeight)
            if ModelComposerKey.showsPlaceholder(text, hasMarkedText: hasMarkedText) {
                Text("Ask a question…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, ModelComposerMetrics.placeholderLeading)
                    .padding(.top, ModelComposerMetrics.inset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            thumbnails
            editor
            .padding(.horizontal, Space.xxs)
            controls
        }
        .padding(Space.s)
        .background(surface, in: cardShape)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 10, y: 3)
    }

    private var imageHandler: (([Data]) -> Void)? {
        guard canAttach else { return nil }
        return { addImages($0) }
    }

    private var mediaHandler: (([URL]) -> Void)? {
        guard canAttachVideo || canAttachAudio else { return nil }
        return { addFiles($0) }
    }

    /// Routes picked files by type: images, one movie, one audio file. Movies and audio are decoded off the main thread.
    private func addFiles(_ urls: [URL]) {
        var imageData: [Data] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch ModelChatMedia.kind(of: url) {
            case .video where canAttachVideo && video == nil: loadMedia(url) { video = ModelDraftVideo(try await ModelChatMedia.videoClip(from: $0)) }
            case .audio where canAttachAudio && audio == nil: loadMedia(url) { audio = ModelDraftAudio(clip: try await ModelChatMedia.audioClip(from: $0)) }
            case .none: if let data = try? Data(contentsOf: url) { imageData.append(data) }
            default: break
            }
        }
        addImages(imageData)
    }

    /// Movie and audio decoding reads the file lazily, so the security scope is held until it finishes.
    private func loadMedia(_ url: URL, _ attach: @escaping @MainActor (URL) async throws -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        attachProblem = nil
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await attach(url) } catch { attachProblem = error.localizedDescription }
        }
    }

    /// Decodes and downscales off the main thread, then appends up to the per-message limit.
    private func addImages(_ originals: [Data]) {
        let room = ModelChatAttachments.maximumPerMessage - images.count
        guard canAttach, room > 0, !originals.isEmpty else { return }
        Task {
            let added = await Task.detached { originals.prefix(room).compactMap { ModelDraftImage($0) } }.value
            images.append(contentsOf: added.prefix(ModelChatAttachments.maximumPerMessage - images.count))
        }
    }

    @ViewBuilder private var thumbnails: some View {
        if let attachProblem {
            Label(attachProblem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Status.warning).padding(.horizontal, Space.xxs)
        }
        if hasAttachments {
            HStack(spacing: Space.s) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ModelDraftThumbnail(image: image, index: index + 1, count: images.count) {
                        images.removeAll { $0.id == image.id }
                    }
                }
                if let video {
                    ModelDraftVideoThumbnail(video: video) { self.video = nil }
                }
                if let audio {
                    ModelDraftAudioChip(audio: audio) { self.audio = nil }
                }
            }
            .padding(.horizontal, Space.xxs).padding(.top, 2)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
        }
    }

    private var attachHelp: String {
        guard canAttachAny else { return "The selected model can’t read images, video or audio" }
        let kinds = [canAttach ? "images" : nil, canAttachVideo ? "video" : nil, canAttachAudio ? "audio" : nil].compactMap { $0 }
        let missing = canAttachAudio ? "" : ". Audio: \(audioUnavailableReason)"
        return "Attach " + kinds.joined(separator: ", ") + missing
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: ModelsChrome.composerRadius, style: .continuous) }

    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.17) : Color(nsColor: .textBackgroundColor)
    }

    private var controls: some View {
        HStack(spacing: Space.s) {
            Button("Attach file", systemImage: "photo.badge.plus") { choosingImages = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: ModelsChrome.composerControl, height: ModelsChrome.composerControl)
                .contentShape(Rectangle())
                .disabled(!canAttachAny)
                .help(attachHelp)
                .accessibilityIdentifier("model-prompt-attach")
            if let modelName {
                HStack(spacing: Space.xs) {
                    Image(systemName: "cpu").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(modelName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    ModelStatusDot(color: modelReady ? Status.running : Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .frame(height: ModelsChrome.composerControl)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: Radius.panel, style: .continuous))
                .help(modelReady ? "Chatting with \(modelName)" : "\(modelName) is not running")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(modelReady ? "Model \(modelName), running" : "Model \(modelName), stopped")
            }
            ViewThatFits(in: .horizontal) {
                Text("Return to send · Shift-Return for a new line")
                Text("Shift-Return for a new line")
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .layoutPriority(-1)
            Spacer(minLength: 4)
            ZStack {
                if state.showsStop {
                    Button("Cancel response", systemImage: "stop.fill", action: stop)
                        .buttonStyle(ControlButtonStyle(tint: Status.stopped))
                        .fixedSize()
                        .disabled(!state.canStop)
                        .help("Stop the response (Esc)")
                        .accessibilityIdentifier("model-prompt-cancel")
                        .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        guard canSend else { return }
                        send()
                    }
                    .buttonStyle(.plain)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 26))
                    .frame(width: ModelsChrome.composerControl, height: ModelsChrome.composerControl)
                    .foregroundStyle(canSend ? AnyShapeStyle(WorkspaceStyle.models.base) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .disabled(!canSend)
                    .help("Send (Return)")
                    .accessibilityIdentifier("model-prompt-send")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(height: ModelsChrome.composerControl)
            .motion(Motion.snappy, value: state.showsStop)
            .motion(Motion.snappy, value: canSend)
        }
    }
}

/// A removable preview. Focus it with Tab and press Delete, or use the VoiceOver "Remove" action.
private struct ModelDraftThumbnail: View {
    let image: ModelDraftImage
    let index: Int
    let count: Int
    let remove: () -> Void

    var body: some View {
        Image(nsImage: image.thumbnail)
            .resizable().scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button("Remove image \(index)", systemImage: "xmark.circle.fill", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: 16)).foregroundStyle(.white, .black.opacity(0.6))
                    .offset(x: 5, y: -5)
                    .help("Remove image")
            }
            .focusable()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in remove(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attached image \(index) of \(count)")
            .accessibilityAction(named: "Remove image", remove)
    }
}

/// A removable video preview: first frame with a duration badge.
private struct ModelDraftVideoThumbnail: View {
    let video: ModelDraftVideo
    let remove: () -> Void

    var body: some View {
        Image(nsImage: ModelChatMedia.badged(video.thumbnail, duration: video.clip.duration))
            .resizable().scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(alignment: .topTrailing) { removeButton("Remove video", action: remove) }
            .focusable()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in remove(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attached video, \(ModelChatMedia.clock(video.clip.duration))")
            .accessibilityAction(named: "Remove video", remove)
    }
}

/// A removable audio chip: waveform and duration.
private struct ModelDraftAudioChip: View {
    let audio: ModelDraftAudio
    let remove: () -> Void

    var body: some View {
        Label(ModelChatMedia.clock(audio.clip.duration), systemImage: "waveform")
            .font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: Control.height)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: Radius.panel, style: .continuous))
            .overlay(alignment: .topTrailing) { removeButton("Remove audio", action: remove) }
            .help(audio.clip.name)
            .focusable()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in remove(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attached audio, \(ModelChatMedia.clock(audio.clip.duration))")
            .accessibilityAction(named: "Remove audio", remove)
    }
}

private func removeButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    Button(title, systemImage: "xmark.circle.fill", action: action)
        .labelStyle(.iconOnly).buttonStyle(.plain)
        .font(.system(size: 16)).foregroundStyle(.white, .black.opacity(0.6))
        .offset(x: 5, y: -5)
}
