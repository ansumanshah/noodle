import AppKit
import SwiftUI

/// SwiftUI owns pane visibility. AppKit sizes the native window.
struct WorkspaceWindow: NSViewRepresentable {
    let showsInspector: Bool

    func makeNSView(context: Context) -> Bridge { Bridge() }

    func updateNSView(_ view: Bridge, context: Context) {
        view.showsInspector = showsInspector
        view.scheduleUpdate()
    }

    final class Bridge: NSView {
        var showsInspector = false
        private var wasShowingInspector = false
        private var updateScheduled = false
        private var automaticResize: (before: CGFloat, after: CGFloat)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            wasShowingInspector = false
            automaticResize = nil
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updateScheduled, window != nil else { return }
            updateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateScheduled = false
                guard let window else { return }
                updateWidth(of: window)
            }
        }

        private func updateWidth(of window: NSWindow) {
            guard showsInspector != wasShowingInspector else { return }
            wasShowingInspector = showsInspector
            guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
                  let visibleFrame = window.screen?.visibleFrame else {
                automaticResize = nil
                return
            }
            var frame = window.frame
            if showsInspector {
                let target = min(WorkspaceStyle.inspectorWindowWidth, visibleFrame.width)
                guard frame.width < target else { return }
                automaticResize = (frame.width, target)
                frame.size.width = target
            } else {
                defer { automaticResize = nil }
                guard let resize = automaticResize, abs(frame.width - resize.after) < 1 else { return }
                frame.size.width = resize.before
            }
            frame.origin.x = max(visibleFrame.minX, min(frame.minX, visibleFrame.maxX - frame.width))
            window.setFrame(frame, display: true)
        }

    }
}
