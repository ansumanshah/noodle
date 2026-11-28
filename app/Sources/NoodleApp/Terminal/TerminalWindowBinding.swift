import SwiftUI

private struct TerminalWorkspaceKey: FocusedValueKey { typealias Value = TerminalWorkspace }

extension FocusedValues {
    var terminalWorkspace: TerminalWorkspace? {
        get { self[TerminalWorkspaceKey.self] }
        set { self[TerminalWorkspaceKey.self] = newValue }
    }
}

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalWorkspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle Terminal") { workspace?.toggle() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(workspace == nil)
            // Command-1...9 belongs to the sidebar routes, so tabs cycle with Control-Tab.
            Button("Next Terminal Tab") { workspace?.selectNext() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(workspace?.isOpen != true)
            Button("Previous Terminal Tab") { workspace?.selectNext(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(workspace?.isOpen != true)
        }
    }
}

@MainActor
enum TerminalWindows {
    private final class Entry {
        weak var workspace: TerminalWorkspace?
        init(_ workspace: TerminalWorkspace) { self.workspace = workspace }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func register(_ workspace: TerminalWorkspace, window: NSWindow) {
        entries[ObjectIdentifier(window)] = Entry(workspace)
    }

    static func unregister(window: NSWindow) { entries[ObjectIdentifier(window)] = nil }

    static func workspace(for window: NSWindow?) -> TerminalWorkspace? {
        window.flatMap { entries[ObjectIdentifier($0)]?.workspace }
    }

    static var current: TerminalWorkspace? { workspace(for: NSApp.keyWindow) ?? workspace(for: NSApp.mainWindow) }

    static func closeAll() {
        for entry in entries.values { entry.workspace?.closePanel() }
    }
}

struct TerminalWindowBinding: NSViewRepresentable {
    let workspace: TerminalWorkspace

    func makeNSView(context: Context) -> TerminalWindowObserver { TerminalWindowObserver(workspace: workspace) }
    func updateNSView(_ nsView: TerminalWindowObserver, context: Context) {}
    static func dismantleNSView(_ nsView: TerminalWindowObserver, coordinator: ()) { nsView.detach() }
}

@MainActor
final class TerminalWindowObserver: NSView {
    private let workspace: TerminalWorkspace
    private weak var observedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(workspace: TerminalWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        detach()
        guard let window else { return }
        observedWindow = window
        TerminalWindows.register(workspace, window: window)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak workspace] _ in
            MainActor.assumeIsolated { workspace?.closePanel() }
        }
    }

    func detach() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let observedWindow {
            TerminalWindows.unregister(window: observedWindow)
            workspace.closePanel()
        }
        observedWindow = nil
    }
}
