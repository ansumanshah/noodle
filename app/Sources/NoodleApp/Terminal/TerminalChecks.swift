import AppKit
import Darwin
import NoodleCore
import SwiftTerm

/// Headless app checks. Run with NOODLE_NO_ACTIVATE=1 NoodleApp --terminal-self-test.
/// No engine connection, VM, window, login startup file or installed Docker tool is used.
@MainActor
enum TerminalChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() -> Int32 {
        do {
            _ = NSApplication.shared
            try launchArguments()
            try missingDocker()
            try discoveredDocker()
            try tabsAndSplits()
            try processCleanup()
            print("PASS terminal-launch-arguments terminal-missing-docker terminal-discovered-docker terminal-tabs-splits terminal-scrollback terminal-process-cleanup terminal-window-close")
            return 0
        } catch {
            FileHandle.standardError.write(Data("FAIL terminal-self-test: \(error)\n".utf8))
            return 1
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func launchArguments() throws {
        let socket = "/tmp/noodle's socket/docker.sock"
        let docker = URL(fileURLWithPath: "/tmp/Noodle tools/docker")
        let id = "id; echo must-remain-an-argument"
        let inherited = ["DOCKER_CONTEXT": "other", "DOCKER_TLS_VERIFY": "1", "DOCKER_CERT_PATH": "/wrong",
                         "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        let launch = TerminalLaunch.make(socketPath: socket, docker: docker, containerID: id, inherited: inherited)
        try expect(launch.executable == docker.path, "Container launch must use Noodle's absolute Docker path")
        try expect(Array(launch.arguments.prefix(5)) == ["--host", "unix://" + socket, "exec", "-it", id], "Socket and ID must stay separate arguments")
        try expect(launch.environment.contains("DOCKER_HOST=unix://" + socket), "Wrong Docker socket")
        guard let cleanup = launch.guestCleanup else { throw Failure(description: "Container launch must describe how to hang up its shell") }
        try expect(launch.arguments.last == cleanup.token && cleanup.arguments.last == cleanup.token, "Shell and cleanup must share the session token")
        try expect(Array(cleanup.arguments.prefix(4)) == ["--host", "unix://" + socket, "exec", id], "Cleanup must keep the container ID as one argument")
        try expect(!launch.environment.contains { $0.hasPrefix("DOCKER_CONTEXT=") || $0.hasPrefix("DOCKER_TLS_VERIFY=") || $0.hasPrefix("DOCKER_CERT_PATH=") }, "Inherited Docker overrides leaked")
        let shell = TerminalLaunch.make(socketPath: socket, docker: docker, inherited: inherited)
        try expect(shell.executable == "/bin/sh" && shell.arguments == ["-l"], "Plain tab must run the login shell")
        try expect(shell.environment.contains("PATH=/tmp/Noodle tools:/usr/bin:/bin"), "Managed Docker must be on the shell PATH")
    }

    private static func tabsAndSplits() throws {
        let workspace = TerminalWorkspace(socketPath: "/tmp/unused.sock", docker: URL(fileURLWithPath: "/unused/docker"), demo: true)
        defer { workspace.closePanel() }
        workspace.open()
        guard let first = workspace.selected, let original = first.sessions[first.activePane] else { throw Failure(description: "Missing first tab") }
        let terminal = original.makeTerminal(onFocus: {})
        terminal.feed(text: "\r\nscrollback-canary\r\n" + String(repeating: "next line\r\n", count: 100))
        try expect(terminal.findNext("scrollback-canary"), "Find must search output above the viewport")
        first.split(.horizontal, demo: true)
        let sibling = first.activePane
        first.split(.vertical, demo: true)
        try expect(first.layout.panes.count == 3 && Set(first.layout.panes).count == 3, "Nested splits lost panes")
        try expect(!first.closePane(sibling) && first.layout.panes.count == 2, "Closing a split must collapse its branch")
        workspace.open()
        try expect(workspace.tabs.count == 2 && workspace.selectedTab != first.id, "New tab must select itself")
        workspace.selectedTab = first.id
        try expect(original.makeTerminal(onFocus: {}) === terminal, "Tab switch replaced the terminal and lost scrollback")
        workspace.closeTab(first.id)
        try expect(original.terminal == nil && first.sessions.isEmpty && workspace.tabs.count == 1, "Closing tab retained terminal resources")
        workspace.toggle()
        try expect(!workspace.isOpen && workspace.tabs.isEmpty, "Closing panel retained tabs")
        workspace.toggle()
        try expect(workspace.isOpen && workspace.tabs.count == 1, "Reopening panel must create a fresh shell")

        // A real, never-ordered window tests the same notification used by window chrome.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = TerminalWindowObserver(workspace: workspace)
        window.contentView?.addSubview(observer)
        try expect(TerminalWindows.workspace(for: window) === workspace, "Window did not register its workspace")
        window.close()
        try expect(!workspace.isOpen && workspace.tabs.isEmpty, "Window close retained sessions")
        observer.detach()
    }

    private static func missingDocker() throws {
        let docker = URL(fileURLWithPath: "/nonexistent-noodle-terminal-check/tools/docker")
        let launch = TerminalLaunch.make(socketPath: "/tmp/unused.sock", docker: docker, containerID: "unused")
        let session = TerminalSession(launch: launch, demo: false)
        defer { session.stop() }
        let terminal = session.makeTerminal(onFocus: {})
        try expect(session.status?.contains("noodle tools install") == true, "Missing Docker must show the install command")
        try expect(terminal.findNext("noodle tools install"), "Install command must appear in terminal output")
        try expect(terminal.process.shellPid == 0, "Missing managed Docker must not start a fallback process")
    }

    /// A compatible docker elsewhere on the Mac must not trigger the "Docker tool missing" message.
    private static func discoveredDocker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-terminal-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = bin.appendingPathComponent("docker")
        try "#!/bin/sh\necho 'Docker version 27.0.1, build abc'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let paths = NoodlePaths(root: root.appendingPathComponent("noodle"))
        let discovery = ToolDiscovery(env: ["PATH": bin.path, "HOME": root.path, "DOCKER_CONFIG": root.path + "/cfg"], paths: paths)
        let docker = TerminalLaunch.docker(paths: paths, discovery: discovery)
        try expect(docker.path == fake.path, "Terminal must use the docker found on this Mac")
        let launch = TerminalLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: ["PATH=/usr/bin:/bin"], managedDocker: docker.path)
        let session = TerminalSession(launch: launch, demo: false)
        defer { session.stop() }
        _ = session.makeTerminal(onFocus: {})
        try expect(session.status?.contains("Docker tool missing") != true, "A discovered docker must not be reported missing")
    }

    private static func processCleanup() throws {
        let launch = TerminalLaunch(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 20 ]; do sleep 120 & i=$((i+1)); done; wait"], environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"], managedDocker: nil)
        let session = TerminalSession(launch: launch, demo: false)
        defer { session.stop() }
        let terminal = session.makeTerminal(onFocus: {})
        let pid = terminal.process.shellPid
        try expect(pid > 1, "PTY child did not start")
        var children: [pid_t] = []
        try until("Shell did not start all 20 background jobs") {
            children = TerminalProcessCleanup.childPIDs(of: pid)
            return children.count == 20
        }
        session.stop()
        try expect(session.terminal == nil, "Session kept its terminal after close")
        try until("Closing a terminal left its shell or background job alive") {
            kill(pid, 0) == -1 && errno == ESRCH && children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
        }
        session.stop() // Closing twice must be harmless.
    }

    private static func until(_ message: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { throw Failure(description: message) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
