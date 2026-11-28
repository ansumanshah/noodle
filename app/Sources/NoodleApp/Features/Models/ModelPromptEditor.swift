// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
import AppKit
import SwiftUI

@MainActor
struct ModelPromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let state: ModelComposerState
    let onMarkedTextChanged: (Bool) -> Void
    let onSend: () -> Void
    let onCancel: () -> Void
    var onImages: (([Data]) -> Void)?
    var onMedia: (([URL]) -> Void)?
    /// Attachments make an empty message sendable.
    var hasAttachments = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    // Kept separate so the native editor's real input-method behavior can be
    // checked offscreen, without activating an app or ordering a window front.
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let tv = ModelComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        tv.delegate = coordinator
        tv.isEditable = state.isEditable
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.textContainerInset = ModelComposerMetrics.inset
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = ModelComposerMetrics.lineFragmentPadding
        tv.autoresizingMask = [.width]
        tv.string = text
        tv.setAccessibilityLabel("Ask a question")
        tv.setAccessibilityIdentifier("model-prompt-editor")
        tv.onCompositionChanged = { [weak coordinator] in coordinator?.textChanged() }
        tv.onLayout = { [weak coordinator] in coordinator?.recomputeHeight() }
        tv.onImages = onImages
        tv.onMedia = onMedia
        scroll.documentView = tv
        coordinator.textView = tv
        coordinator.recomputeHeight()
        return scroll
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ModelPromptEditor
        weak var textView: ModelComposerTextView?
        private var pendingHeight: CGFloat?
        private var heightUpdateScheduled = false

        init(_ parent: ModelPromptEditor) { self.parent = parent }

        func update(parent: ModelPromptEditor) {
            self.parent = parent
            guard let tv = textView else { return }
            if ModelComposerKey.shouldAdoptExternalText(
                field: tv.string, bound: parent.text, hasMarkedText: tv.hasMarkedText()) {
                tv.string = parent.text
                tv.setSelectedRange(NSRange(location: (parent.text as NSString).length, length: 0))
            }
            tv.onImages = parent.onImages
            tv.onMedia = parent.onMedia
            if tv.isEditable != parent.state.isEditable { tv.isEditable = parent.state.isEditable }
            recomputeHeight()
        }

        func textDidChange(_ notification: Notification) { textChanged() }

        func textChanged() {
            guard let tv = textView else { return }
            let marked = tv.hasMarkedText()
            parent.onMarkedTextChanged(marked)
            // The binding contains committed text only. Both directions must
            // protect marked text: a stream redraw must not replace IME input.
            if !marked, parent.text != tv.string { parent.text = tv.string }
            recomputeHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { return handleCancel() }
            let literalNewline = selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            guard literalNewline || selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return handleReturn(shift: literalNewline || (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        }

        func handleReturn(shift: Bool) -> Bool {
            guard let tv = textView else { return false }
            switch ModelComposerKey.onReturn(shift: shift, canSend: parent.state.canSend(tv.string, hasAttachments: parent.hasAttachments),
                                             hasMarkedText: tv.hasMarkedText()) {
            case .confirmMarkedText: return false
            case .ignore: return true
            case .newline:
                guard parent.state.isEditable else { return true }
                tv.insertNewlineIgnoringFieldEditor(self)
                return true
            case .send:
                textChanged()
                parent.onSend()
                return true
            }
        }

        func handleCancel() -> Bool {
            guard let tv = textView, !tv.hasMarkedText(), parent.state.canStop else { return false }
            parent.onCancel()
            return true
        }

        func recomputeHeight() {
            guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = tv.font.map { layout.defaultLineHeight(for: $0) } ?? 20
            let size = ModelComposerMetrics.resolve(contentHeight: layout.usedRect(for: container).height,
                                                     lineHeight: line)
            tv.enclosingScrollView?.hasVerticalScroller = false
            pendingHeight = size.height
            guard !heightUpdateScheduled, abs(parent.measuredHeight - size.height) > 0.5 else { return }
            heightUpdateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                guard let height = self.pendingHeight, abs(self.parent.measuredHeight - height) > 0.5 else { return }
                self.parent.measuredHeight = height
            }
        }
    }
}
