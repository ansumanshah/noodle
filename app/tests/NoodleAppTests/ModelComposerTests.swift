import AppKit
import SwiftUI
import Testing
@testable import NoodleApp

@MainActor
struct ModelComposerTests {
    @Test(arguments: ModelComposerState.allCases)
    func stateGatesEditingSendingAndCancellation(state: ModelComposerState) {
        #expect(state.isEditable == (state == .ready || state == .responding))
        #expect(state.canStop == (state == .responding))
        #expect(state.showsStop == (state == .responding || state == .cancelling))
        #expect(state.canSend("Hello") == (state == .ready))
        #expect(!state.canSend(" \n\t"))
        #expect(!state.canSend(""))
    }

    @Test func markedTextHasPriorityOverReturnAndShiftReturn() {
        for shift in [false, true] {
            #expect(ModelComposerKey.onReturn(shift: shift, canSend: true, hasMarkedText: true) == .confirmMarkedText)
        }
        #expect(ModelComposerKey.onReturn(shift: false, canSend: false, hasMarkedText: false) == .ignore)
        #expect(ModelComposerKey.onReturn(shift: true, canSend: false, hasMarkedText: false) == .newline)
        #expect(!ModelComposerKey.showsPlaceholder("", hasMarkedText: true))
    }

    @Test func nativeMarkedTextSurvivesBindingRedrawAndCommitsOnlyWhenFinished() throws {
        let fixture = try Fixture(state: .ready)
        fixture.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.textView.hasMarkedText())
        #expect(fixture.draft.marked)
        #expect(fixture.draft.text.isEmpty)
        fixture.draft.text = "An external redraw"
        fixture.coordinator.update(parent: fixture.editor)
        #expect(fixture.textView.string == "に")
        #expect(!fixture.coordinator.handleReturn(shift: false))
        #expect(!fixture.coordinator.handleReturn(shift: true))
        #expect(fixture.draft.sends == 0)
        fixture.textView.insertText("日本語", replacementRange: fixture.textView.markedRange())
        #expect(!fixture.textView.hasMarkedText())
        #expect(!fixture.draft.marked)
        #expect(fixture.draft.text == "日本語")
        fixture.coordinator.update(parent: fixture.editor)
        #expect(fixture.textView.string == "日本語")
    }

    @Test func nativeReturnSendsAndShiftReturnInsertsNewline() throws {
        let fixture = try Fixture(state: .ready, text: "Hello")
        fixture.textView.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(fixture.coordinator.handleReturn(shift: true))
        #expect(fixture.textView.string == "Hello\n")
        #expect(fixture.draft.text == "Hello\n")
        #expect(fixture.draft.sends == 0)
        #expect(fixture.coordinator.handleReturn(shift: false))
        #expect(fixture.draft.sends == 1)
        #expect(fixture.textView.string == "Hello\n")
    }

    @Test func blankAndReceivingDraftsCannotSend() throws {
        for state in ModelComposerState.allCases {
            let fixture = try Fixture(state: state, text: state == .ready ? " \n" : "Next question")
            #expect(fixture.coordinator.handleReturn(shift: false))
            #expect(fixture.draft.sends == 0)
            #expect(fixture.textView.isEditable == state.isEditable)
        }
        let receiving = try Fixture(state: .responding, text: "Next question")
        receiving.textView.setSelectedRange(NSRange(location: 13, length: 0))
        #expect(receiving.coordinator.handleReturn(shift: true))
        #expect(receiving.draft.text == "Next question\n")
    }

    @Test func escapeCancelsOnlyAnActiveResponseAndPreservesComposition() throws {
        for state in ModelComposerState.allCases {
            let fixture = try Fixture(state: state)
            #expect(fixture.coordinator.handleCancel() == (state == .responding))
            #expect(fixture.draft.stops == (state == .responding ? 1 : 0))
        }
        let fixture = try Fixture(state: .responding)
        fixture.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!fixture.coordinator.handleCancel())
        #expect(fixture.draft.stops == 0)
    }

    @Test func externalClearResetsCaretButUnchangedRedrawPreservesSelection() throws {
        let fixture = try Fixture(state: .ready, text: "Hello world")
        fixture.textView.setSelectedRange(NSRange(location: 1, length: 4))
        fixture.coordinator.update(parent: fixture.editor)
        #expect(fixture.textView.selectedRange() == NSRange(location: 1, length: 4))
        fixture.draft.text = ""
        fixture.coordinator.update(parent: fixture.editor)
        #expect(fixture.textView.string.isEmpty)
        #expect(fixture.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func editorGrowsToSixLinesThenScrollsAndKeepsNativeEditing() throws {
        let small = ModelComposerMetrics.resolve(contentHeight: 0, lineHeight: 20)
        let six = ModelComposerMetrics.resolve(contentHeight: 120, lineHeight: 20)
        let overflow = ModelComposerMetrics.resolve(contentHeight: 1000, lineHeight: 20)
        #expect(small.height == 36)
        #expect(!small.scrolls)
        #expect(six.height == 136)
        #expect(!six.scrolls)
        #expect(overflow.height == six.height)
        #expect(overflow.scrolls)
        let fixture = try Fixture(state: .ready)
        #expect(fixture.textView.allowsUndo)
        #expect(!fixture.textView.isRichText)
        fixture.textView.insertText("a pasted\nmultiline draft", replacementRange: NSRange(location: 0, length: 0))
        #expect(fixture.draft.text == "a pasted\nmultiline draft")
    }

    @MainActor private final class Draft {
        var text = ""
        var height: CGFloat = 36
        var marked = false
        var sends = 0
        var stops = 0
    }

    @MainActor private struct Fixture {
        let draft: Draft
        let editor: ModelPromptEditor
        let coordinator: ModelPromptEditor.Coordinator
        // Retain the scroll view, which owns its native text view and undo context.
        let scroll: NSScrollView
        let textView: ModelComposerTextView

        init(state: ModelComposerState, text: String = "") throws {
            let draft = Draft()
            draft.text = text
            let editor = ModelPromptEditor(
                text: Binding(get: { draft.text }, set: { draft.text = $0 }),
                measuredHeight: Binding(get: { draft.height }, set: { draft.height = $0 }),
                state: state, onMarkedTextChanged: { draft.marked = $0 },
                onSend: { draft.sends += 1 }, onCancel: { draft.stops += 1 })
            let coordinator = editor.makeCoordinator()
            let scroll = editor.makeScrollView(coordinator: coordinator)
            self.draft = draft
            self.editor = editor
            self.coordinator = coordinator
            self.scroll = scroll
            textView = try #require(scroll.documentView as? ModelComposerTextView)
        }
    }
}
