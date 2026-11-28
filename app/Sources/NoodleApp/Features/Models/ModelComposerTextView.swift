// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
import AppKit

enum ModelComposerKey {
    enum ReturnAction: Equatable { case send, newline, ignore, confirmMarkedText }

    static func onReturn(shift: Bool, canSend: Bool, hasMarkedText: Bool) -> ReturnAction {
        if hasMarkedText { return .confirmMarkedText }
        if shift { return .newline }
        return canSend ? .send : .ignore
    }

    static func shouldAdoptExternalText(field: String, bound: String, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && field != bound
    }

    static func showsPlaceholder(_ text: String, hasMarkedText: Bool) -> Bool {
        text.isEmpty && !hasMarkedText
    }
}

enum ModelComposerMetrics {
    static let inset = NSSize(width: 7, height: 8)
    static let lineFragmentPadding: CGFloat = 2
    static var placeholderLeading: CGFloat { inset.width + lineFragmentPadding }

    static func resolve(contentHeight: CGFloat, lineHeight: CGFloat) -> (height: CGFloat, scrolls: Bool) {
        let minimum = lineHeight + inset.height * 2
        let maximum = lineHeight * 6 + inset.height * 2
        let natural = contentHeight + inset.height * 2
        return (max(minimum, min(natural, maximum)), natural > maximum + 0.5)
    }
}

@MainActor
final class ModelComposerTextView: NSTextView {
    var onCompositionChanged: (() -> Void)?
    var onLayout: (() -> Void)?
    /// Set only while the model can read images; otherwise paste and drops behave as plain text.
    var onImages: (([Data]) -> Void)?
    /// Set only while video or audio files can be attached; the composer filters by kind.
    var onMedia: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        let media = onMedia == nil ? [] : ModelChatMedia.mediaFiles(in: .general)
        if !media.isEmpty { return onMedia?(media) ?? () }
        let images = onImages == nil ? [] : ModelChatAttachments.images(in: .general)
        if images.isEmpty { super.paste(sender) } else { onImages?(images) }
    }

    private func acceptsDrop(_ sender: any NSDraggingInfo) -> Bool {
        (onImages != nil && ModelChatAttachments.hasImages(sender.draggingPasteboard))
            || (onMedia != nil && !ModelChatMedia.mediaFiles(in: sender.draggingPasteboard).isEmpty)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrop(sender) else { return super.performDragOperation(sender) }
        let media = onMedia == nil ? [] : ModelChatMedia.mediaFiles(in: sender.draggingPasteboard)
        if !media.isEmpty { onMedia?(media) } else { onImages?(ModelChatAttachments.images(in: sender.draggingPasteboard)) }
        return true
    }

    override func setMarkedText(_ markedString: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(markedString, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChanged?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onCompositionChanged?()
    }

    private var focusObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        guard window != nil else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: ModelComposerFocus.notification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeRequestedFocus() }
        }
        takeRequestedFocus()
    }

    private func takeRequestedFocus() {
        guard ModelComposerFocus.pending, let window else { return }
        ModelComposerFocus.pending = false
        window.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
