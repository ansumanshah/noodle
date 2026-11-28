import AppKit
import Testing
@testable import NoodleApp

@MainActor
struct CompactScrollbarTests {
    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func hiddenScrollbarsKeepTheDocumentScrollable(style: NSScroller.Style) {
        let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.scrollerStyle = style
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = true

        CompactScrollbars.Bridge.apply(to: view)
        #expect(!view.hasVerticalScroller)
        #expect(!view.hasHorizontalScroller)
        #expect(view.verticalScroller == nil)
        #expect(view.horizontalScroller == nil)
        #expect(view.scrollerStyle == style)
        view.contentView.scroll(to: NSPoint(x: 40, y: 50))
        view.reflectScrolledClipView(view.contentView)
        #expect(view.contentView.bounds.origin.x == 40)
        #expect(view.contentView.bounds.origin.y == 50)
        CompactScrollbars.Bridge.apply(to: view)
        #expect(view.contentView.bounds.origin == NSPoint(x: 40, y: 50))
    }
}
