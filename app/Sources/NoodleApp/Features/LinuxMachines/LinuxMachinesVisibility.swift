import SwiftUI
import AppKit

/// Observe window occlusion rather than key-window status, so a visible background window stays current.
struct MachineWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.changed = { visible = $0 }
        return view
    }
    func updateNSView(_ nsView: ObserverView, context: Context) {}
    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) { nsView.stop() }

    final class ObserverView: NSView {
        var changed: ((Bool) -> Void)?
        private var observations: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { publish(); return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observations.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.publish() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.publish() }
                })
            }
            publish()
        }
        private func publish() {
            let isVisible = window?.occlusionState.contains(.visible) == true && !NSApp.isHidden
            // Defer state writes until after AppKit finishes updating the representable.
            Task { @MainActor [weak self] in self?.changed?(isVisible) }
        }
        func stop() {
            for token in observations { NotificationCenter.default.removeObserver(token) }
            observations.removeAll()
        }
    }
}
