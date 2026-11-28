import SwiftUI
import AppKit

struct NoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup("Noodle", id: "main") {
            RootView(env: env)
                .background(MainWindowVisibilityReader().frame(width: 0, height: 0))
                .preferredColorScheme(env.demo && ProcessInfo.processInfo.environment["NOODLE_DEMO_LIGHT"] == "1" ? .light : nil)
        }
        .defaultSize(WorkspaceStyle.defaultWindowSize)
        .windowResizability(.contentMinSize)
        // Pages carry no title, so a full-height toolbar band would sit empty above them.
        // Regular height leaves about 10 pt above and below the 32 pt controls, close to the 12 pt side insets.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.presented)
        .commands { NoodleCommands(env: env); TerminalCommands() }

        MenuBarExtra {
            MenuBarContent(env: env)
        } label: {
            MenuBarLabel(env: env)
        }

        Settings { SettingsView(env: env) }.windowResizability(.contentMinSize)
    }
}

struct MenuBarOnlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared
    var body: some Scene {
        MenuBarExtra { MenuBarContent(env: env) } label: { MenuBarLabel(env: env) }
        Settings { SettingsView(env: env) }.windowResizability(.contentMinSize)
    }
}

/// Why two processes: a SwiftUI window scene keeps ~30 MB of view-graph and AppKit state alive after the
/// window closes. When the last window closes the app hands over to a copy of itself that runs only the
/// menu bar item (16 MB). "Open Noodle" in that copy starts the full app and exits.
enum Relaunch {
    static var isMenuBarOnly: Bool { CommandLine.arguments.contains("--menubar-only") }

    @discardableResult
    @MainActor static func spawn(menuBarOnly: Bool, open destination: Destination? = nil, extraArguments: [String] = []) -> Bool {
        guard AppEnvironment.shared.nav.canChangeInstallation else { return false }
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(from: CommandLine.arguments, menuBarOnly: menuBarOnly, open: destination) + extraArguments
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    static func arguments(from original: [String], menuBarOnly: Bool, open destination: Destination? = nil) -> [String] {
        var args = original.dropFirst().filter { arg in
            arg != "--menubar-only" && !Destination.argumentPrefixes.contains { arg.hasPrefix($0) } && !arg.hasPrefix("--demo-select=")
                && !arg.hasPrefix("--demo-page=") && !arg.hasPrefix("--demo-tab=") && arg != "--demo-setup" && arg != QuickAsk.focusArgument
        }
        if menuBarOnly { args.append("--menubar-only") }
        if let destination { args += destination.arguments }
        return Array(args)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: AppEnvironment
    override init() { environment = .shared; super.init() }
    init(environment: AppEnvironment) { self.environment = environment; super.init() }
    private var closeObserver: NSObjectProtocol?
    private var visibilityObservers: [NSObjectProtocol] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(QuickAsk.focusArgument) { ModelComposerFocus.pending = true }
        QuickAsk.apply()
        if Relaunch.isMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
            AppEnvironment.shared.sync.setWindowVisible(false)
        } else {
            NSApp.setActivationPolicy(.regular)
            // Test runs stay behind whatever the user is doing.
            if ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] == nil { NSApp.activate() }
            else { BackgroundMainWindow.presentIfRequested() }
            if !AppEnvironment.shared.demo { Updater.shared.launch() }
        }
        // Debug aid for memory measurement: NOODLE_DEBUG_CLOSE_AFTER=<seconds> closes the main window.
        if let after = ProcessInfo.processInfo.environment["NOODLE_DEBUG_CLOSE_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.close()
            }
        }
        if let after = ProcessInfo.processInfo.environment["NOODLE_DEBUG_OPEN_AFTER"].flatMap(Double.init), Relaunch.isMenuBarOnly {
            Task { try? await Task.sleep(for: .seconds(after)); AppEnvironment.shared.showMainWindow() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard window.styleMask.contains(.titled) else { return }
                self?.windowClosing(window)
            }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainWindowVisibility.update() }
            })
        }
    }

    private func windowClosing(_ window: NSWindow) {
        guard !terminating, !Relaunch.isMenuBarOnly, AppEnvironment.shared.nav.canChangeInstallation else { return }
        MainWindowVisibility.update(excluding: window)
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        guard !others else { return }
        // The display can close while the VM, a download, an install or a reply keeps running in this app process.
        if WindowCloseWork.current(AppEnvironment.shared).keepsProcess {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // The menu bar copy carries the page, so reopening lands where the window closed.
        if Relaunch.spawn(menuBarOnly: true, open: .route(AppEnvironment.shared.nav.route)) {
            // Let the menu bar copy put its icon up, then leave.
            Task { try? await Task.sleep(for: .milliseconds(700)); NSApp.terminate(nil) }
        } else {
            NSApp.setActivationPolicy(.accessory)   // fall back to staying in this process
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let env = environment
        if env.nav.installationBusy { return .terminateCancel }
        if env.macMachine.isActive {
            env.macMachine.error = "Finish or cancel installation, or shut down the macOS machine before quitting Noodle."
            env.nav.open(.macMachine)
            if ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] == nil { env.showMainWindow() }
            return .terminateCancel
        }
        terminating = true
        TerminalWindows.closeAll()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppEnvironment.shared.showMainWindow() } }
        return true
    }
}

extension AppEnvironment {
    @MainActor func showMainWindow(_ destination: Destination? = nil, extraArguments: [String] = []) {
        guard nav.canChangeInstallation else { return }
        if Relaunch.isMenuBarOnly {
            if Relaunch.spawn(menuBarOnly: false, open: destination ?? .route(nav.route), extraArguments: extraArguments) {
                Task { try? await Task.sleep(for: .milliseconds(800)); NSApp.terminate(nil) }
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        let background = ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] != nil
        if !background { NSApp.activate() }
        if !demo { Updater.shared.windowOpened() }
        if let destination { nav.open(destination) }
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if background { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
        } else {
            openMain?()
        }
    }
}
