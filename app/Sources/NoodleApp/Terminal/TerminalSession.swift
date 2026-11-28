import AppKit
import Darwin
import Observation
import SwiftTerm
/// Owns the PTY across tab switches. Only explicit pane, tab, panel or window close stops it.
@MainActor @Observable
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let launch: TerminalLaunch
    let demo: Bool
    private(set) var status: String?
    @ObservationIgnored private(set) var terminal: EmbeddedTerminalView?
    @ObservationIgnored private var stopped = false
    init(launch: TerminalLaunch, demo: Bool) {
        self.launch = launch
        self.demo = demo
    }
    func makeTerminal(onFocus: @escaping () -> Void) -> EmbeddedTerminalView {
        if let terminal {
            terminal.onFocus = onFocus
            return terminal
        }
        let view = EmbeddedTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.blockProgramClipboardAccess()
        view.onFocus = onFocus
        view.processDelegate = self
        view.setAccessibilityLabel("Interactive terminal")
        terminal = view
        guard !stopped else { view.updateUiClosed(); return view }
        if demo {
            view.feed(text: "Noodle terminal\r\n$ docker ps\r\nCONTAINER ID   IMAGE          STATUS\r\n8a31f08c712e   postgres:17    Up 2 hours\r\n\r\n$ ")
        } else {
            if let docker = launch.managedDocker, !FileManager.default.isExecutableFile(atPath: docker) {
                status = "Docker tool missing. Run: noodle tools install"
                view.feed(text: "\r\nNoodle's managed Docker tool is missing at \(docker).\r\nInstall it with: noodle tools install\r\n\r\n")
                if launch.executable == docker { return view }
            }
            guard FileManager.default.isExecutableFile(atPath: launch.executable) else {
                status = "Terminal executable unavailable: \(launch.executable)"
                view.feed(text: "\r\n\(status ?? "Terminal executable unavailable")\r\n")
                return view
            }
            view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment,
                              currentDirectory: NSHomeDirectory())
        }
        return view
    }
    func find() {
        guard let terminal else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal.performFindPanelAction(item)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let view = terminal else { return }
        view.onFocus = nil
        view.processDelegate = nil
        // Stop UI drivers explicitly: NSView can stay retained during SwiftUI's removal transition.
        // We use SwiftTerm's default Core Graphics renderer, so no committed GPU work needs retrying.
        view.updateUiClosed()
        let pid = view.process.shellPid
        if pid > 0 {
            TerminalProcessCleanup.stopTree(pid)
            view.terminate()
            if let cleanup = launch.guestCleanup { TerminalProcessCleanup.hangUpGuestShell(cleanup) }
        }
        view.removeFromSuperview()
        terminal = nil
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        status = exitCode.map { "Exited (\($0))" } ?? "Process ended"
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        status = "Could not start terminal: \(error)"
    }
}
/// No polling, helper process or delayed PID-based kill. Capture identities before signalling.
enum TerminalProcessCleanup {
    private struct Identity {
        let pid: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }
    private static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Identity(pid: pid, parent: pid_t(info.pbi_ppid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    @discardableResult
    private static func signal(_ process: Identity, _ signal: Int32) -> Bool {
        guard let current = identity(process.pid), current.parent == process.parent,
              current.seconds == process.seconds, current.microseconds == process.microseconds else { return false }
        return kill(process.pid, signal) == 0
    }
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        var capacity = 16
        while true {
            var children = [pid_t](repeating: 0, count: capacity)
            let filled = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { return [] }
            // proc_listchildpids returns a pid count, and a full buffer may be truncated.
            if Int(filled) < capacity {
                return Array(children.prefix(Int(filled))).filter { $0 > 1 }
            }
            capacity *= 2
        }
    }
    /// Signals the shell inside the container with a second, short-lived docker exec. It runs on a utility queue
    /// (never the main actor) and is killed after five seconds, so a wedged daemon cannot leave it behind.
    static func hangUpGuestShell(_ cleanup: TerminalLaunch.GuestCleanup) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cleanup.docker)
            process.arguments = cleanup.arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
            process.waitUntilExit()
            deadline.cancel()
        }
    }
    static func stopTree(_ pid: pid_t) {
        guard pid > 1, pid != getpid(), let root = identity(pid), root.parent == getpid() else { return }
        var visited = Set<pid_t>()
        func stop(_ process: Identity) {
            guard visited.insert(process.pid).inserted else { return }
            // Freeze each parent before listing children so it cannot fork more jobs during close.
            guard signal(process, SIGSTOP) else { return }
            for child in childPIDs(of: process.pid) {
                if let info = identity(child), info.parent == process.pid { stop(info) }
            }
            signal(process, SIGKILL)
        }
        stop(root)
    }
}

@MainActor
final class EmbeddedTerminalView: LocalProcessTerminalView {
    var appliedTheme: String?
    var onFocus: (() -> Void)?
    var clipboardGuard: ClipboardBlockingDelegate?

    // becomeFirstResponder is not open in SwiftTerm; a click is how a pane gains focus.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocus?()
    }
}

extension EmbeddedTerminalView {
    /// Programs inside a container can emit OSC 52 to write or read the Mac clipboard. SwiftTerm's
    /// clipboard hooks are not overridable, so the view's delegate is swapped for a wrapper that
    /// ignores those two requests. Menu copy and paste go straight to the pasteboard and are unaffected.
    func blockProgramClipboardAccess() {
        let wrapper = ClipboardBlockingDelegate(view: self)
        clipboardGuard = wrapper
        terminalDelegate = wrapper
    }
}

/// Forwards every delegate call to the view's own implementation except clipboard access by the
/// running program, which is dropped. The view keeps the strong reference; SwiftTerm holds it weakly.
@MainActor
final class ClipboardBlockingDelegate: TerminalViewDelegate {
    private unowned let view: EmbeddedTerminalView
    init(view: EmbeddedTerminalView) { self.view = view }

    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { view.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { view.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { view.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { view.requestOpenLink(source: source, link: link, params: params) }
    func bell(source: TerminalView) { view.bell(source: source) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { view.iTermContent(source: source, content: content) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view.rangeChanged(source: source, startY: startY, endY: endY) }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { [] }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { .denied }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .denied }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
}
