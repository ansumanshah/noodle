import AppKit
import SwiftUI

extension View {
    func compactScrollbars() -> some View {
        scrollIndicators(.never)
            .background(CompactScrollbars().frame(width: 0, height: 0))
    }
}

/// Applies to AppKit scroll views in a Noodle window, hiding all scrollbars completely.
struct CompactScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> Bridge { Bridge() }
    func updateNSView(_ view: Bridge, context: Context) { view.schedule() }

    final class Bridge: NSView {
        private static var pendingWindows: Set<ObjectIdentifier> = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        override func layout() {
            super.layout()
            schedule()
        }

        func schedule() {
            guard let window else { return }
            let id = ObjectIdentifier(window)
            guard Self.pendingWindows.insert(id).inserted else { return }
            Task { @MainActor [weak window] in
                Self.pendingWindows.remove(id)
                if let content = window?.contentView { Self.apply(to: content) }
            }
        }

        static func apply(to view: NSView) {
            if let scroll = view as? NSScrollView {
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.verticalScroller = nil
                scroll.horizontalScroller = nil
                scroll.autohidesScrollers = true
                scroll.tile()
            }
            for child in view.subviews { apply(to: child) }
        }
    }
}
