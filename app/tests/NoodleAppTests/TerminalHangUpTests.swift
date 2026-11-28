import Foundation
import Testing
@testable import NoodleApp

/// 142237b: closing a container terminal hangs up the in-container shell with a second docker exec.
@Suite(.tags(.slow)) struct TerminalHangUpTests {
    private func launch() throws -> (TerminalLaunch, TerminalLaunch.GuestCleanup) {
        let launch = TerminalLaunch.make(socketPath: "/tmp/n.sock", docker: URL(fileURLWithPath: "/tmp/tools/docker"),
                                         containerID: "abc123", inherited: ["PATH": "/usr/bin"])
        return (launch, try #require(launch.guestCleanup))
    }

    @Test func shellAndCleanupShareTheSessionToken() throws {
        let (launch, cleanup) = try launch()
        #expect(launch.arguments.last == cleanup.token)
        #expect(cleanup.arguments.last == cleanup.token)
        #expect(Array(cleanup.arguments.prefix(4)) == ["--host", "unix:///tmp/n.sock", "exec", "abc123"])
        #expect(!cleanup.arguments.contains("-it"), "cleanup must not need a terminal")
    }

    @Test func plainShellTabHasNoGuestCleanup() {
        let plain = TerminalLaunch.make(socketPath: "/tmp/n.sock", docker: URL(fileURLWithPath: "/tmp/tools/docker"), inherited: [:])
        #expect(plain.guestCleanup == nil)
    }

    @MainActor @Test func splitPanesKeepIndependentLaunchAndCleanupTokens() throws {
        let (launch, _) = try launch()
        let tab = TerminalTab(title: "Shell", launch: launch, demo: true)
        let original = tab.activePane
        tab.split(.horizontal, demo: true)
        tab.split(.vertical, demo: true)
        let launches = tab.sessions.values.map(\.launch)
        let tokens = try launches.map { try #require($0.guestCleanup?.token) }
        #expect(Set(tokens).count == 3)
        for pane in launches {
            let cleanup = try #require(pane.guestCleanup)
            #expect(pane.arguments.last == cleanup.token && cleanup.arguments.last == cleanup.token)
            #expect(cleanup.socketPath == "/tmp/n.sock" && cleanup.containerID == "abc123")
            #expect(pane.environment == launch.environment)
        }
        let survivor = try #require(tab.sessions[tab.activePane])
        #expect(!tab.closePane(original))
        #expect(tab.sessions[survivor.id] === survivor)
        #expect(tab.layout.panes.count == 2)
        tab.stop()
    }

    /// Runs both scripts under /bin/sh as the guest would: the shell records its pid, cleanup signals it.
    @Test func cleanupScriptHangsUpTheShellAndRemovesTheRecord() async throws {
        let (launch, cleanup) = try launch()
        let script = try #require(launch.arguments.firstIndex(of: "-c").map { launch.arguments[$0 + 1] })
        let record = "/tmp/.noodle-term-\(cleanup.token)"
        defer { try? FileManager.default.removeItem(atPath: record) }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", cleanup.token]
        let stdin = Pipe()   // held open so the shell keeps waiting for input
        shell.standardInput = stdin
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        defer { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }

        var recorded = false
        for _ in 0..<100 {
            if let text = try? String(contentsOfFile: record, encoding: .utf8), Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == shell.processIdentifier { recorded = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorded, "the shell must write its pid to the per-session file")
        #expect(shell.isRunning)

        // cleanup.arguments is `docker --host .. exec <id> sh -c <script> sh <token>`; run the same script locally.
        let tail = Array(cleanup.arguments.drop { $0 != "sh" }.dropFirst())
        let hangUp = Process()
        hangUp.executableURL = URL(fileURLWithPath: "/bin/sh")
        hangUp.arguments = tail
        try hangUp.run()
        hangUp.waitUntilExit()

        var exited = false
        for _ in 0..<100 { if !shell.isRunning { exited = true; break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(exited, "the in-container shell was not hung up")
        #expect(!FileManager.default.fileExists(atPath: record))
        _ = stdin
    }
}
