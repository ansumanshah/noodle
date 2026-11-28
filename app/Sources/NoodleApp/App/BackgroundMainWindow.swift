import AppKit
import SwiftUI

/// A deterministic background-only host for verifying the real workspace without activation.
/// Normal launches continue to use the SwiftUI window scene.
@MainActor
enum BackgroundMainWindow {
    private static var requested = false
    private static var retainedWindow: NSWindow?

    static func presentIfRequested() {
        guard !requested, !Relaunch.isMenuBarOnly,
              ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] != nil else { return }
        requested = true
        DispatchQueue.main.async {
            // Automatic scene creation, if it completed, owns the existing window.
            if let existing = NSApp.windows.first(where: {
                $0.styleMask.contains(.titled) && $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                // AppKit restores the user's saved frame ("NSWindow Frame main-AppWindow-1") over `.defaultSize`.
                // Demo captures need the default size and must not overwrite that saved frame.
                if AppEnvironment.shared.demo {
                    existing.setFrameAutosaveName("")
                    existing.setFrame(NSRect(origin: existing.frame.origin, size: DemoFlags.windowSize), display: false)
                }
                existing.orderBack(nil)
                debug("reused main window behind existing windows")
                return
            }
            let env = AppEnvironment.shared
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: WorkspaceStyle.defaultWindowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Noodle"
            window.toolbarStyle = .unifiedCompact
            window.identifier = NSUserInterfaceItemIdentifier("main-background-verification")
            window.isReleasedWhenClosed = false
            window.contentMinSize = WorkspaceStyle.minWindowSize
            window.contentView = NSHostingView(rootView:
                RootView(env: env)
                    .background(MainWindowVisibilityReader().frame(width: 0, height: 0))
                    .preferredColorScheme(env.demo && ProcessInfo.processInfo.environment["NOODLE_DEMO_LIGHT"] == "1" ? .light : nil))
            retainedWindow = window
            // Match the scene's `.defaultSize`, which is the outer frame; the content rect above excludes the toolbar.
            window.setFrame(NSRect(origin: .zero, size: env.demo ? DemoFlags.windowSize : WorkspaceStyle.defaultWindowSize), display: false)
            window.center()
            window.orderBack(nil)
            debug("created real workspace behind existing windows")
        }
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["NOODLE_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("background launch: \(message)\n".utf8))
    }
}
