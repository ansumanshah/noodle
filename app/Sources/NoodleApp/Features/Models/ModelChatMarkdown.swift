import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Marks fenced code lines; the transcript's layout manager draws one rounded panel behind each block.
    static let modelCodeBlock = NSAttributedString.Key("NoodleModelCodeBlock")
    /// Marks a user turn; the transcript's layout manager draws a bubble behind it.
    static let modelUserBubble = NSAttributedString.Key("NoodleModelUserBubble")
}

/// Foundation handles inline Markdown; simple block treatment preserves line breaks and code.
/// Parsing happens once for a completed message, never for each streaming update.
enum ModelChatMarkdown {
    /// Prose leading (1.4); code gets rows, not air.
    static let proseLineHeight: CGFloat = 1.32
    static let codeInset: CGFloat = 12
    static var codeFont: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    private static let notice = ModelPromptStream.lengthNotice.trimmingCharacters(in: .whitespacesAndNewlines)

    static func render(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var codeBlock = false
        var codeOpened = false
        var lastCodeLine: NSRange?
        let lines = text.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            // A reply cut at the token limit can end inside a fence. The notice is ours, never code.
            if trimmed == notice { codeBlock = false }
            if trimmed.hasPrefix("```") {
                codeBlock.toggle()
                codeOpened = codeBlock
                if !codeBlock, let range = lastCodeLine { closeCodeBlock(result, line: range) }
                continue
            }
            var line = original
            var headingLevel = 0
            if !codeBlock {
                headingLevel = min(6, line.prefix(while: { $0 == "#" }).count)
                if headingLevel > 0, line.dropFirst(headingLevel).first == " " {
                    line = String(line.dropFirst(headingLevel + 1))
                } else { headingLevel = 0 }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
                if line.hasPrefix("> ") { line = "│ " + line.dropFirst(2) }
            }
            let paragraph = NSMutableParagraphStyle()
            if codeBlock {
                paragraph.lineHeightMultiple = 1.15
                paragraph.firstLineHeadIndent = codeInset
                paragraph.headIndent = codeInset
                paragraph.tailIndent = -codeInset
                if codeOpened { paragraph.paragraphSpacingBefore = 12; codeOpened = false }
            } else {
                paragraph.lineHeightMultiple = proseLineHeight
                if headingLevel > 0 { paragraph.paragraphSpacingBefore = 6; paragraph.paragraphSpacing = 2 }
                if line.hasPrefix("• ") || line.hasPrefix("│ ") {
                    paragraph.headIndent = 14
                    paragraph.firstLineHeadIndent = 2
                }
            }
            let lineFont = codeBlock ? codeFont
                : headingLevel > 0 ? NSFont.systemFont(ofSize: max(14, 21 - CGFloat(headingLevel)), weight: .semibold) : font
            let attributes: [NSAttributedString.Key: Any] = [
                .font: lineFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            if codeBlock {
                var codeAttributes = attributes
                codeAttributes[.modelCodeBlock] = true
                lastCodeLine = NSRange(location: result.length, length: (line as NSString).length)
                result.append(NSAttributedString(string: line, attributes: codeAttributes))
            } else if let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    var runAttributes = attributes
                    if let intent = run.inlinePresentationIntent {
                        if intent.contains(.code) {
                            runAttributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
                            runAttributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.16)
                        } else {
                            var traits: NSFontTraitMask = []
                            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                            if !traits.isEmpty { runAttributes[.font] = NSFontManager.shared.convert(lineFont, toHaveTrait: traits) }
                            if intent.contains(.strikethrough) { runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                        }
                    }
                    if let link = run.link { runAttributes[.link] = link }
                    result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: runAttributes))
                }
            } else {
                result.append(NSAttributedString(string: line, attributes: attributes))
            }
            if index < lines.count - 1 {
                var breakAttributes = attributes
                if codeBlock { breakAttributes[.modelCodeBlock] = true }
                result.append(NSAttributedString(string: "\n", attributes: breakAttributes))
            }
        }
        return result
    }

    /// Air under a closed fence so the panel does not touch the prose that follows.
    private static func closeCodeBlock(_ text: NSMutableAttributedString, line: NSRange) {
        guard line.location < text.length,
              let style = text.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle,
              let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
        copy.paragraphSpacing = 12
        text.addAttribute(.paragraphStyle, value: copy, range: NSRange(location: line.location, length: max(1, line.length)))
    }
}
