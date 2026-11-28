import AppKit
import NoodleCore
import SwiftUI

/// One native document permits selection across messages and avoids nested scroll panes.
struct ModelChatTranscriptView: NSViewRepresentable {
    let conversationID: UUID?
    let messages: [ModelChatMessage]
    let liveText: String
    let fallbackText: String
    let receiving: Bool
    var onAction: (ModelMessageAction, ModelChatMessage) -> Void = { _, _ in }

    func makeNSView(context: Context) -> ModelChatScrollView { ModelChatScrollView() }

    func updateNSView(_ view: ModelChatScrollView, context: Context) {
        view.onAction = onAction
        view.apply(conversationID: conversationID, messages: messages, liveText: liveText,
                   fallbackText: fallbackText, receiving: receiving)
    }
}

@MainActor
final class ModelChatScrollView: NSScrollView {
    private let transcript: NSTextView = {
        // TextKit 1 with a layout manager that draws the bubbles and code panels.
        let storage = NSTextStorage()
        let manager = ModelChatLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        return ModelChatTextView(frame: .zero, textContainer: container)
    }()
    private var conversationID: UUID?
    private var messageIDs: [UUID] = []
    private var messageContents: [String] = []
    private var liveText = ""
    /// UTF-16 length and last 32 units of the appended live text, so a token append checks only the boundary.
    private var liveLength = 0, liveTail = ""
    private var fallbackText = ""
    private func extendsLive(_ text: NSString) -> Bool {
        let n = (liveTail as NSString).length
        return text.length >= liveLength && text.substring(with: NSRange(location: liveLength - n, length: n)) == liveTail
    }
    private var receiving = false
    private var initialized = false
    private var sizing = false
    private var cachedMessages: [UUID: (content: String, rendered: NSAttributedString)] = [:]
    private let bodyFont = NSFont.systemFont(ofSize: 14)
    private var builtForWidth: CGFloat = 0
    private var messages: [ModelChatMessage] = []
    var onAction: (ModelMessageAction, ModelChatMessage) -> Void = { _, _ in }
    /// Each message's character range, including the gap after it, so the pointer in the gap keeps its toolbar.
    private var messageRanges: [NSRange] = []
    private var hoveredID: UUID?
    private let actions = ModelMessageActionsState()
    private lazy var actionsView = NSHostingView(rootView: ModelMessageActionsBar(state: actions))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: ModelsChrome.gutter, height: 28)
        transcript.isHorizontallyResizable = false
        transcript.isVerticallyResizable = true
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainer?.lineBreakMode = .byWordWrapping
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.setAccessibilityLabel("Model conversation")
        transcript.setAccessibilityIdentifier("model-chat-transcript")
        documentView = transcript
        actions.perform = { [weak self] action in self?.perform(action) }
        actionsView.isHidden = true
        transcript.addSubview(actionsView)
        (transcript as? ModelChatTextView)?.hover = { [weak self] point in self?.hover(at: point) }
    }

    private func hover(at point: NSPoint?) {
        var id: UUID?
        if let point, !receiving, let container = transcript.textContainer, let manager = transcript.layoutManager,
           (transcript.textStorage?.length ?? 0) > 0 {
            let local = NSPoint(x: point.x - transcript.textContainerOrigin.x, y: point.y - transcript.textContainerOrigin.y)
            let index = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if let position = messageRanges.firstIndex(where: { NSLocationInRange(index, $0) }), messages.indices.contains(position) {
                id = messages[position].id
            }
        }
        guard id != hoveredID else { return }
        hoveredID = id
        updateActions()
    }

    private func updateActions() {
        guard let id = hoveredID, !receiving, let position = messages.firstIndex(where: { $0.id == id }),
              messageRanges.indices.contains(position), let container = transcript.textContainer,
              let manager = transcript.layoutManager else {
            actions.visible = false
            return
        }
        let message = messages[position]
        actions.role = message.role
        actions.canRegenerate = position == messages.count - 1
        let glyphs = manager.glyphRange(forCharacterRange: messageRanges[position], actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let size = actionsView.fittingSize
        let origin = transcript.textContainerOrigin
        let left = origin.x, right = origin.x + container.containerSize.width - ModelsChrome.bubblePaddingH
        actionsView.frame = NSRect(x: message.role == .user ? right - size.width : left,
                                   y: origin.y + rect.maxY - size.height - 4, width: size.width, height: size.height)
        actionsView.isHidden = false
        actions.visible = true
    }

    private func perform(_ action: ModelMessageAction) {
        guard let message = messages.first(where: { $0.id == hoveredID }) else { return }
        if action == .copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } else {
            actions.visible = false
            hoveredID = nil
            onAction(action, message)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() { super.layout(); sizeDocument() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); sizeDocument() }

    func apply(conversationID: UUID?, messages: [ModelChatMessage], liveText: String,
               fallbackText: String, receiving: Bool) {
        let changedConversation = initialized && self.conversationID != conversationID
        let ids = messages.map(\.id)
        let contents = messages.map(\.content)
        let historyChanged = messageIDs != ids || messageContents != contents
        let width = containerWidth
        let changed = !initialized || changedConversation || historyChanged || self.liveText != liveText
            || self.fallbackText != fallbackText || self.receiving != receiving || abs(builtForWidth - width) > 0.5
        guard changed, let storage = transcript.textStorage else { return }
        let origin = contentView.bounds.origin
        let selection = transcript.selectedRanges
        let distance = ModelResponseScrollPolicy.distanceFromBottom(
            contentHeight: transcript.bounds.height, offsetY: origin.y, viewportHeight: contentView.bounds.height)
        let follows = !initialized || changedConversation || ModelResponseScrollPolicy.followsAppend(
            distanceFromBottom: distance, hasSelection: selection.contains { $0.rangeValue.length > 0 })

        // During a response, mutate only the new suffix. Completed Markdown is cached.
        if initialized, !changedConversation, !historyChanged, self.receiving, receiving, abs(builtForWidth - width) <= 0.5,
           self.fallbackText == fallbackText, extendsLive(liveText as NSString) {
            let suffix = (liveText as NSString).substring(from: liveLength)
            storage.append(NSAttributedString(string: suffix, attributes: bodyAttributes))
        } else {
            let document = NSMutableAttributedString(string: "")
            var ranges: [NSRange] = []
            for message in messages {
                let start = document.length
                defer { ranges.append(NSRange(location: start, length: document.length - start)) }
                var status: String?
                switch message.state {
                case .cancelled: status = "Response cancelled"
                case .failed: status = "Response interrupted"
                case .truncated: status = "Shortened in saved history"
                default: break
                }
                if message.role == .user {
                    if let status { document.append(heading(status, trailing: true)) }
                    if let strip = attachmentStrip(message.attachments ?? []) { document.append(strip) }
                    document.append(userBubble(message.content, width: width))
                } else {
                    document.append(heading("Noodle", status: status))
                    if let cached = cachedMessages[message.id], cached.content == message.content {
                        document.append(cached.rendered)
                    } else {
                        let rendered = ModelChatMarkdown.render(message.content, font: bodyFont)
                        cachedMessages[message.id] = (message.content, rendered)
                        document.append(rendered)
                    }
                }
                document.append(turnBreak)
            }
            messageRanges = ranges
            if receiving {
                document.append(heading("Noodle"))
                document.append(NSAttributedString(string: liveText, attributes: bodyAttributes))
            } else if messages.isEmpty, !fallbackText.isEmpty {
                document.append(heading("Noodle"))
                document.append(ModelChatMarkdown.render(fallbackText, font: bodyFont))
            }
            storage.setAttributedString(document)
            let retained = Set(ids)
            cachedMessages = cachedMessages.filter { retained.contains($0.key) }
        }
        self.conversationID = conversationID
        self.messageIDs = ids
        self.messageContents = contents
        self.liveText = liveText
        let live = liveText as NSString
        liveLength = live.length; liveTail = live.substring(from: max(0, live.length - 32))
        self.fallbackText = fallbackText
        self.receiving = receiving
        self.messages = messages
        builtForWidth = width
        initialized = true
        sizeDocument()
        if changedConversation {
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
        } else {
            let length = storage.length
            transcript.selectedRanges = selection.map {
                let range = $0.rangeValue
                let start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
        }
        updateActions()
        position(at: follows ? NSPoint(x: 0, y: transcript.frame.height - contentView.bounds.height) : origin)
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = ModelChatMarkdown.proseLineHeight
        return [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    /// Width the text container lays out in: the reading measure, or the view when narrower.
    private var containerWidth: CGFloat {
        max(1, contentView.bounds.width - Self.inset(for: contentView.bounds.width) * 2)
    }

    private static func inset(for width: CGFloat) -> CGFloat {
        max(ModelsChrome.gutter, ((width - ModelsChrome.readingWidth) / 2).rounded())
    }

    /// Ends a turn and leaves air before the next one; the empty line is sized, not a stack of newlines.
    private var turnBreak: NSAttributedString {
        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = 22
        gap.maximumLineHeight = 22
        return NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: gap])
    }

    /// What a saved attachment shows: the image, a video's first frame with its duration, or an audio chip.
    private static func preview(_ name: String, _ data: Data, index: Int, count: Int) -> (NSImage, String)? {
        switch name.split(separator: ".").last {
        case "vid":
            guard let clip = try? JSONDecoder().decode(ModelVideoClip.self, from: data), let first = clip.frames.first,
                  let frame = NSImage(data: first) else { return nil }
            return (ModelChatMedia.badged(frame, duration: clip.duration), String(localized: "Attached video, \(ModelChatMedia.clock(clip.duration))"))
        case "wav":
            let seconds = ModelChatMedia.wavDuration(data)
            return (ModelChatMedia.audioChip(duration: seconds, height: 36), String(localized: "Attached audio, \(ModelChatMedia.clock(seconds))"))
        default:
            return NSImage(data: data).map { ($0, String(localized: "Attached image \(index + 1) of \(count)")) }
        }
    }

    /// Thumbnails of a user message's images, right-aligned above its bubble. The home is the app's own.
    private func attachmentStrip(_ names: [String]) -> NSAttributedString? {
        let home = NoodlePaths.resolve().root
        let thumbnailHeight: CGFloat = 96
        let strip = NSMutableAttributedString()
        for (index, name) in names.enumerated() {
            guard let data = ModelChatAttachments.load(name, home: home), let (image, label) = Self.preview(name, data, index: index, count: names.count),
                  image.size.height > 0 else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            // An audio chip keeps its own compact height.
            let height = name.hasSuffix(".wav") ? image.size.height : thumbnailHeight
            let scale = height / image.size.height
            attachment.bounds = CGRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: height)
            image.accessibilityDescription = label
            strip.append(NSAttributedString(attachment: attachment))
            strip.append(NSAttributedString(string: " "))
        }
        guard strip.length > 0 else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.tailIndent = -ModelsChrome.bubblePaddingH
        paragraph.paragraphSpacingBefore = ModelsChrome.bubblePaddingV
        strip.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: strip.length))
        strip.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph, .font: bodyFont]))
        return strip
    }

    /// A user turn: leading-aligned text, pushed right so the bubble hugs its widest line.
    private func userBubble(_ content: String, width: CGFloat) -> NSAttributedString {
        let padding = ModelsChrome.bubblePaddingH
        let maximum = max(120, (width * 0.78).rounded() - padding * 2)
        let measure: [NSAttributedString.Key: Any] = [.font: bodyFont]
        let widest = content.components(separatedBy: "\n").map {
            ceil(($0 as NSString).size(withAttributes: measure).width)
        }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.tailIndent = -padding
        let indent = max(0, width - padding - min(widest + 1, maximum))
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.paragraphSpacingBefore = ModelsChrome.bubblePaddingV
        return NSAttributedString(string: content, attributes: [
            .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph, .modelUserBubble: true,
        ])
    }

    private func heading(_ name: String, status: String? = nil, trailing: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        if trailing { style.alignment = .right }
        let result = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: trailing ? NSColor.secondaryLabelColor : NSColor(WorkspaceStyle.models.ink),
            .paragraphStyle: style,
        ])
        if let status {
            result.append(NSAttributedString(string: "  ·  " + status, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 12)]))
        return result
    }

    /// The reading measure moved: re-lay the bubbles, which depend on the container width.
    private func rebuildForWidth() {
        guard initialized, abs(builtForWidth - containerWidth) > 0.5 else { return }
        apply(conversationID: conversationID, messages: messages, liveText: liveText,
              fallbackText: fallbackText, receiving: receiving)
        // Bubbles are drawn by the view from glyph bounds. A partial redraw after a width change left the old
        // bubble edge behind for a frame while a reply streamed, so repaint the whole transcript.
        transcript.needsDisplay = true
    }

    private func sizeDocument() {
        guard !sizing, let container = transcript.textContainer, let manager = transcript.layoutManager else { return }
        sizing = true
        defer { sizing = false }
        let origin = contentView.bounds.origin
        let width = max(1, contentView.bounds.width)
        let inset = Self.inset(for: width)
        if transcript.textContainerInset.width != inset {
            transcript.textContainerInset = NSSize(width: inset, height: transcript.textContainerInset.height)
        }
        if transcript.frame.origin != .zero { transcript.setFrameOrigin(.zero) }
        transcript.setFrameSize(NSSize(width: width, height: transcript.frame.height))
        container.containerSize = NSSize(width: max(1, width - transcript.textContainerInset.width * 2),
                                         height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let contentHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        transcript.setFrameSize(NSSize(width: width, height: max(contentView.bounds.height, contentHeight + 48)))
        position(at: origin)
        if initialized, abs(builtForWidth - containerWidth) > 0.5 {
            Task { @MainActor [weak self] in self?.rebuildForWidth() }
        }
    }

    private func position(at point: NSPoint) {
        let maximum = max(0, transcript.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, point.y))))
        reflectScrolledClipView(contentView)
    }
}
