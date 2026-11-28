import SwiftUI
import AppKit

/// Tracks this page's actual window without activating it. Occluded, minimized and closed
/// windows cancel the page task, so Kubernetes adds no polling while it is out of sight.
struct KubernetesWindowVisibility: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ nsView: VisibilityView, context: Context) { nsView.changed = changed }
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.stop() }

    final class VisibilityView: NSView {
        var changed: @MainActor (Bool) -> Void
        init(changed: @escaping @MainActor (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility),
                                                       name: NSWindow.didChangeOcclusionStateNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(stop),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
            updateVisibility()
        }
        @objc private func updateVisibility() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            Task { @MainActor in changed(visible) }
        }
        @objc func stop() {
            NotificationCenter.default.removeObserver(self)
            Task { @MainActor in changed(false) }
        }
    }
}
