import AppKit
import Foundation
import Testing
@testable import NoodleApp

@Suite struct ModelChatMarkdownTests {
    private func isMonospaced(_ text: NSAttributedString, at index: Int) -> Bool {
        let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
    }

    @Test func replyStartingWithHashIsAHeadingNotCode() {
        let text = ModelChatMarkdown.render("# My name is Ada\n\nHello there", font: .systemFont(ofSize: 14))
        #expect(text.string == "My name is Ada\n\nHello there")
        #expect(!isMonospaced(text, at: 0))
        #expect(!isMonospaced(text, at: text.length - 1))
    }

    @Test func hashWithoutSpaceStaysPlainBody() {
        let text = ModelChatMarkdown.render("#1 tip: rest", font: .systemFont(ofSize: 14))
        #expect(text.string == "#1 tip: rest")
        #expect(!isMonospaced(text, at: 0))
    }

    @Test func lengthNoticeAfterAnUnclosedFenceIsNotCode() {
        let reply = "```python\n# My name is Ada.\nprint(1)" + ModelPromptStream.lengthNotice
        let text = ModelChatMarkdown.render(reply, font: .systemFont(ofSize: 14))
        #expect(isMonospaced(text, at: 0), "Fenced content stays code.")
        let notice = (text.string as NSString).range(of: "Reply stopped")
        #expect(notice.location != NSNotFound)
        #expect(!isMonospaced(text, at: notice.location))
    }
}
