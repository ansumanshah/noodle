import AppKit

/// Draws the transcript's chrome behind the text: one bubble per user turn and one rounded panel per
/// fenced code block. Shapes come from attribute runs, so selection and the streaming append are untouched.
/// Bubble geometry: 14 pt padding and radius.
/// Drawn by the view, not the layout manager: a layout manager's background pass is clipped to line fragments.
final class ModelChatTextView: NSTextView {
    /// The pointer position in this view, or nil once it leaves.
    var hover: ((NSPoint?) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let manager = layoutManager as? ModelChatLayoutManager, let container = textContainer {
            NSGraphicsContext.saveGraphicsState()
            manager.drawChrome(in: dirtyRect, container: container, origin: textContainerOrigin)
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(dirtyRect)
    }
}

final class ModelChatLayoutManager: NSLayoutManager {
    static let bubbleColor = NSColor(ModelsChrome.userBubble)
    static let codeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0, alpha: 0.04)
    }
    static let codeStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
    }

    func drawChrome(in dirtyRect: NSRect, container: NSTextContainer, origin: NSPoint) {
        if let storage = textStorage, storage.length > 0 {
            let local = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -24)
            let glyphsToShow = glyphRange(forBoundingRect: local, in: container)
            let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            for range in runs(of: .modelCodeBlock, in: storage, touching: visible) {
                var rect = lineBounds(range, in: container, fullWidth: true)
                guard !rect.isEmpty else { continue }
                rect = rect.insetBy(dx: 0, dy: -7).offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
                Self.codeColor.setFill(); path.fill()
                Self.codeStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
            }
            for range in runs(of: .modelUserBubble, in: storage, touching: visible) {
                var rect = lineBounds(range, in: container, fullWidth: false)
                guard !rect.isEmpty else { continue }
                rect = rect.insetBy(dx: -ModelsChrome.bubblePaddingH, dy: -ModelsChrome.bubblePaddingV)
                    .offsetBy(dx: origin.x, dy: origin.y)
                Self.bubbleColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: ModelsChrome.bubbleRadius, yRadius: ModelsChrome.bubbleRadius).fill()
            }
        }
    }

    /// Whole attribute runs that intersect the visible range, so a half-visible bubble still draws whole.
    private func runs(of key: NSAttributedString.Key, in storage: NSTextStorage, touching visible: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        let all = NSRange(location: 0, length: storage.length)
        var location = visible.location
        while location < NSMaxRange(visible), location < storage.length {
            var effective = NSRange()
            let value = storage.attribute(key, at: location, longestEffectiveRange: &effective, in: all)
            if value != nil { result.append(effective) }
            location = max(NSMaxRange(effective), location + 1)
        }
        return result
    }

    /// Tight glyph bounds per line (bubbles) or full line-fragment width (code panels).
    private func lineBounds(_ characters: NSRange, in container: NSTextContainer, fullWidth: Bool) -> NSRect {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var union = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
            let span = NSIntersectionRange(lineGlyphs, glyphs)
            guard span.length > 0 else { return }
            if fullWidth {
                union = union.union(NSRect(x: fragment.minX, y: used.minY, width: fragment.width, height: used.height))
            } else {
                var tight = self.boundingRect(forGlyphRange: span, in: container)
                if tight.width < 1 { tight.size.width = 0 }
                union = union.union(tight)
            }
        }
        return union
    }
}
