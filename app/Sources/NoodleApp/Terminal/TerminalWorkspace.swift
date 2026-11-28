import AppKit
import NoodleCore
import Observation

/// A launch description keeps container identifiers and socket paths out of shell source.
struct TerminalLaunch: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let managedDocker: String?
    /// Set for container shells. Closing the tab kills the local docker client, which does not end the shell inside.
    var guestCleanup: GuestCleanup?

    /// Every pane records a different guest PID, including panes cloned from this launch.
    func forNewPane() -> Self {
        guard let cleanup = guestCleanup else { return self }
        let token = UUID().uuidString
        var arguments = arguments
        arguments[arguments.count - 1] = token
        return Self(executable: executable, arguments: arguments, environment: environment, managedDocker: managedDocker,
                    guestCleanup: GuestCleanup(docker: cleanup.docker, socketPath: cleanup.socketPath,
                                               containerID: cleanup.containerID, token: token))
    }

    /// How to hang up the in-container shell: it records its pid in a per-session file, and a second exec signals it.
    struct GuestCleanup: Equatable {
        let docker: String
        let socketPath: String
        let containerID: String
        let token: String

        var arguments: [String] {
            ["--host", "unix://" + socketPath, "exec", containerID, "sh", "-c",
             "f=/tmp/.noodle-term-$1; [ -f \"$f\" ] && kill -HUP \"$(cat \"$f\")\" 2>/dev/null; rm -f \"$f\"", "sh", token]
        }
    }

    static func make(socketPath: String, docker: URL, containerID: String? = nil,
                     inherited: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var env = inherited
        env["DOCKER_CONTEXT"] = nil
        env["DOCKER_TLS_VERIFY"] = nil
        env["DOCKER_CERT_PATH"] = nil
        env["DOCKER_HOST"] = "unix://" + socketPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PATH"] = docker.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let shell = env["SHELL"].flatMap { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let token = UUID().uuidString
        let args = containerID.map {
            ["--host", "unix://" + socketPath, "exec", "-it", $0, "sh", "-c",
             "echo $$ > /tmp/.noodle-term-$1 2>/dev/null; if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi", "sh", token]
        } ?? ["-l"]
        var launch = Self(executable: containerID == nil ? shell : docker.path, arguments: args,
                          environment: env.keys.sorted().map { "\($0)=\(env[$0]!)" }, managedDocker: docker.path)
        if let containerID { launch.guestCleanup = GuestCleanup(docker: docker.path, socketPath: socketPath, containerID: containerID, token: token) }
        return launch
    }

    /// A compatible docker CLI already on this Mac, else Noodle's downloaded one. When neither exists
    /// this is still Noodle's tools path, so the terminal can say where the missing tool belongs.
    static func docker(paths: NoodlePaths, discovery: ToolDiscovery? = nil) -> URL {
        let found = (discovery ?? ToolDiscovery(paths: paths)).docker()
        return found.map { URL(fileURLWithPath: $0) } ?? Tools.docker(paths)
    }
}

enum TerminalSplitAxis: Equatable { case horizontal, vertical }

indirect enum TerminalLayout: Equatable {
    case pane(UUID)
    case split(UUID, TerminalSplitAxis, TerminalLayout, TerminalLayout)

    var panes: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    func splitting(_ pane: UUID, with newPane: UUID, axis: TerminalSplitAxis) -> Self {
        switch self {
        case .pane(let id): id == pane ? .split(UUID(), axis, self, .pane(newPane)) : self
        case .split(let id, let direction, let first, let second):
            .split(id, direction, first.splitting(pane, with: newPane, axis: axis), second.splitting(pane, with: newPane, axis: axis))
        }
    }

    func removing(_ pane: UUID) -> Self? {
        switch self {
        case .pane(let id): id == pane ? nil : self
        case .split(let id, let axis, let first, let second):
            switch (first.removing(pane), second.removing(pane)) {
            case (nil, let remaining), (let remaining, nil): remaining
            case (let a?, let b?): .split(id, axis, a, b)
            }
        }
    }
}

@MainActor @Observable
final class TerminalTab: Identifiable {
    let id = UUID()
    let title: String
    let launch: TerminalLaunch
    var layout: TerminalLayout
    var activePane: UUID
    private(set) var sessions: [UUID: TerminalSession]

    init(title: String, launch: TerminalLaunch, demo: Bool) {
        self.title = title
        self.launch = launch
        let session = TerminalSession(launch: launch.forNewPane(), demo: demo)
        layout = .pane(session.id)
        activePane = session.id
        sessions = [session.id: session]
    }

    func split(_ axis: TerminalSplitAxis, demo: Bool) {
        let session = TerminalSession(launch: launch.forNewPane(), demo: demo)
        sessions[session.id] = session
        layout = layout.splitting(activePane, with: session.id, axis: axis)
        activePane = session.id
    }

    func closePane(_ id: UUID) -> Bool {
        sessions.removeValue(forKey: id)?.stop()
        guard let remaining = layout.removing(id) else { return true }
        layout = remaining
        if activePane == id, let first = remaining.panes.first { activePane = first }
        return false
    }

    func stop() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
    }
}

@MainActor @Observable
final class TerminalWorkspace {
    private(set) var tabs: [TerminalTab] = []
    var selectedTab: UUID?
    private(set) var isOpen = false
    let socketPath: String
    /// Looked up each time a terminal opens: finding it runs `docker --version`, which must not happen at launch.
    private let docker: () -> URL
    let demo: Bool

    init(socketPath: String, docker: @autoclosure @escaping () -> URL, demo: Bool) {
        self.socketPath = socketPath
        self.docker = docker
        self.demo = demo
    }

    var selected: TerminalTab? { tabs.first { $0.id == selectedTab } }

    func open(container: ContainerSummary? = nil) {
        let tab = TerminalTab(title: container?.name ?? "Shell",
                              launch: .make(socketPath: socketPath, docker: docker(), containerID: container?.id), demo: demo)
        tabs.append(tab)
        selectedTab = tab.id
        isOpen = true
    }

    func toggle() {
        if isOpen { closePanel() } else { open() }
    }

    func closeTab(_ id: UUID) {
        tabs.first { $0.id == id }?.stop()
        tabs.removeAll { $0.id == id }
        if selectedTab == id { selectedTab = tabs.last?.id }
        if tabs.isEmpty { isOpen = false }
    }

    /// Control-Tab order: wraps around the tab strip.
    func selectNext(by delta: Int = 1) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTab }), !tabs.isEmpty else { return }
        selectedTab = tabs[((index + delta) % tabs.count + tabs.count) % tabs.count].id
    }

    /// Moves a tab to a new position, clamped to the strip. Selection follows the tab id, not the slot.
    func moveTab(_ id: UUID, to position: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(position, 0), tabs.count))
    }

    func closePanel() {
        for tab in tabs { tab.stop() }
        tabs.removeAll()
        selectedTab = nil
        isOpen = false
    }
}
