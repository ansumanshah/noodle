import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct SidebarCardTests {
    /// The card's VM pill and its engine line are both derived from one ConnectionModel, so they cannot contradict
    /// each other. A fresh model keeps this clear of the shared render environment.
    @Test func vmStateAndEngineLineAgree() {
        let connection = ConnectionModel()
        connection.phase = .up
        connection.vmReadiness = nil
        #expect(connection.engineStatusText == "Engine running")
        #expect(connection.vmStateText == "Running", "A running engine never shows its VM as unavailable.")

        connection.phase = .down("stopped")
        #expect(connection.engineStatusText == "Engine stopped")
        #expect(connection.vmStateText == "Offline")

        connection.phase = .connecting
        #expect(connection.engineStatusText == "Connecting…")
        #expect(connection.vmStateText == "Connecting")
    }

    /// The window footer was removed. Its three controls moved: Refresh and Settings onto the card, Terminal into the
    /// toolbar. Icon-only buttons are not readable in the offscreen render, so this checks the source that wires them.
    @Test func footerControlsLiveOnTheCardAndToolbar() throws {
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NoodleApp/App/Shell")
        let sidebar = try String(contentsOf: shell.appendingPathComponent("RuntimeCard.swift"), encoding: .utf8)
        let toolbar = try String(contentsOf: shell.appendingPathComponent("WindowToolbar.swift"), encoding: .utf8)
        #expect(sidebar.contains(#"Button("Refresh", systemImage: "arrow.clockwise")"#) && sidebar.contains("refreshWorkspace()"))
        #expect(sidebar.contains(#"Button("Settings", systemImage: "gearshape")"#) && sidebar.contains("openSettings()"))
        #expect(toolbar.contains(#"Button("Terminal", systemImage: "terminal")"#) && toolbar.contains("terminal.toggle()"))
        #expect(toolbar.contains(#"accessibilityIdentifier("toolbar-terminal")"#))
        #expect(!FileManager.default.fileExists(atPath: shell.appendingPathComponent("DaemonFooter.swift").path))
    }

    /// What the toolbar Terminal button does: the same `toggle()` call, observed through `isOpen`.
    @Test func terminalToggleOpensAndClosesThePanel() {
        let env = RenderHarness.env
        let terminal = TerminalWorkspace(socketPath: env.paths.socket.path, docker: TerminalLaunch.docker(paths: env.paths),
                                         demo: true)
        #expect(!terminal.isOpen)
        terminal.toggle()
        #expect(terminal.isOpen)
        terminal.toggle()
        #expect(!terminal.isOpen)
    }

    /// What the card's Refresh button and ⌘R do: reload the workspace. The demo environment ends up loaded.
    @Test func refreshActionReloadsTheWorkspace() async {
        let env = RenderHarness.env
        await env.sync.refreshWorkspace()
        #expect(env.containers.loaded)
        #expect(!env.containers.items.isEmpty)
    }
}
