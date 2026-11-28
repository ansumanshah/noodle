import AppKit
import SwiftUI

/// Reports whether the window's sidebar column is really collapsed. AppKit can expand or collapse the column
/// on its own (a resize to the minimum width, the system sidebar command), and the SwiftUI visibility binding
/// does not always hear about it, so the toolbar dot follows this instead.
///
/// Why they drift: NSSplitView autosaves the collapsed state ("NSSplitView Subview Frames main-AppWindow-1,
/// SidebarNavigationSplitView") and restores it when the window opens. SwiftUI then applies its initial
/// visibility as a toggle, so a launch whose saved state already matched the request flipped the column.
/// With `--demo-sidebar=hidden` every second launch showed the sidebar while the binding said hidden.
struct SidebarCollapseReader: NSViewRepresentable {
    /// When set, the column is put in this state once on attach, whatever was restored.
    var initial: Bool?
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Observer { Observer(initial: initial, changed: changed) }
    func updateNSView(_ view: Observer, context: Context) { view.changed = changed }

    final class Observer: NSView {
        var changed: (Bool) -> Void
        private var initial: Bool?
        private var observation: NSKeyValueObservation?
        private var lastReported: Bool?

        init(initial: Bool?, changed: @escaping (Bool) -> Void) {
            self.initial = initial
            self.changed = changed
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            lastReported = nil
            guard window != nil else { return }
            // The split view controller is installed after the first layout pass.
            Task { @MainActor [weak self] in self?.attach(tries: 20) }
        }

        private func attach(tries: Int) {
            guard observation == nil, window != nil else { return }
            guard let item = sidebarItem() else {
                guard tries > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.attach(tries: tries - 1) }
                return
            }
            if let initial {
                self.initial = nil
                if item.isCollapsed != initial { item.isCollapsed = initial }
            }
            observation = item.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
                let collapsed = item.isCollapsed
                Task { @MainActor [weak self] in self?.report(collapsed) }
            }
        }

        private func report(_ collapsed: Bool) {
            guard collapsed != lastReported else { return }
            lastReported = collapsed
            if ProcessInfo.processInfo.environment["NOODLE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("sidebar collapsed=\(collapsed) window=\(window?.frame.size ?? .zero)\n".utf8))
            }
            changed(collapsed)
        }

        /// SwiftUI's split view is driven by an NSSplitViewController, which is the split view's delegate.
        private func sidebarItem() -> NSSplitViewItem? {
            guard let content = window?.contentView else { return nil }
            return Self.splitControllers(in: content).lazy
                .compactMap { $0.splitViewItems.first { $0.behavior == .sidebar } }.first
        }

        private static func splitControllers(in view: NSView) -> [NSSplitViewController] {
            var found: [NSSplitViewController] = []
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController { found.append(controller) }
            for sub in view.subviews { found += splitControllers(in: sub) }
            return found
        }
    }
}
