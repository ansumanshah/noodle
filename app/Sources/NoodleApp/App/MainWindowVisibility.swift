import AppKit
import SwiftUI

/// Recomputed from window events, with the closing window excluded before AppKit removes it.
enum MainWindowVisibility {
    struct Window {
        let id: Int
        let isMain: Bool
        let visible: Bool
    }

    static func isVisible(_ windows: [Window], excluding closingID: Int? = nil, appHidden: Bool = false) -> Bool {
        !appHidden && windows.contains { $0.id != closingID && $0.isMain && $0.visible }
    }

    @MainActor static func update(env: AppEnvironment = .shared, excluding closing: NSWindow? = nil) {
        let windows = NSApp.windows.map {
            Window(id: $0.windowNumber, isMain: $0.identifier?.rawValue.hasPrefix("main") == true,
                   visible: $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible))
        }
        // Demo data costs nothing to refresh, and screenshots capture demo windows behind other work.
        env.sync.setWindowVisible(env.demo || isVisible(windows, excluding: closing?.windowNumber, appHidden: NSApp.isHidden))
    }
}

/// Handles initial attachment too, when a window's first visibility notification preceded its content.
struct MainWindowVisibilityReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor in MainWindowVisibility.update() }
        }
    }
}
