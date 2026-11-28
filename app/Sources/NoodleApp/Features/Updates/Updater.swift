import SwiftUI
import AppKit
import NoodleCore

/// App side of updates (engine: NoodleCore/Update). One tolerant timer checks every six hours
/// while automatic checks are enabled. A verified download is staged; the install only
/// happens when the person chooses Restart.
@MainActor @Observable final class Updater {
    static let shared = Updater()

    enum Status: Equatable {
        case idle, checking, upToDate, downloading(String), ready(String), installing, failed(String), unavailable
    }

    private(set) var status: Status = .idle
    let restartError = ProcessInfo.processInfo.environment[UpdateCommandOutcome.restartErrorEnvironmentKey]
    var automatic: Bool {
        get { settings.automatic }
        set {
            settings.automatic = newValue
            try? settings.save(paths)
            if !newValue { automaticTask?.cancel(); automaticTask = nil }
            scheduleAutomaticCheck()
        }
    }
    private var settings: UpdateSettings
    @ObservationIgnored private let paths: NoodlePaths
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private let config = UpdateConfig.load(infoPlist: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))

    private init() {
        let paths = NoodlePaths.resolve()
        self.paths = paths
        settings = UpdateSettings.load(paths)
        if config == nil { status = .unavailable }
        else if let s = UpdateStore.load(paths), s.phase == .staged, FileManager.default.fileExists(atPath: s.stagedApp) { status = .ready(s.version) }
    }

    var currentVersion: String { config?.currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") }

    /// Called once from applicationDidFinishLaunching in the full app.
    func launch() {
        guard !launched else { return }
        launched = true
        if UpdateInstaller.launchCheck(paths: paths) { Relaunch.reopenApp(restartError: restartError); return }
        if UpdateStore.load(paths)?.phase == .installed {
            Task {   // healthy for 30 s
                try? await Task.sleep(for: .seconds(30))
                UpdateInstaller.confirm(paths: paths)
                refreshManagedTools()
            }
        }
        scheduleAutomaticCheck()
    }

    private func scheduleAutomaticCheck() {
        timer?.invalidate()
        timer = nil
        guard launched, config != nil, automaticTask == nil,
              let next = UpdatePolicy.nextCheck(automatic: settings.automatic, lastCheck: settings.lastCheck, now: Date()) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runAutomaticCheck() }
        }
        timer.tolerance = 15 * 60
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runAutomaticCheck() {
        guard settings.automatic, automaticTask == nil else { return }
        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.check()
            // A cancelled task may have been replaced after toggling back on.
            guard !Task.isCancelled else { return }
            self.automaticTask = nil
            self.scheduleAutomaticCheck()
        }
    }

    /// The main window opened: run the automatic check now if it is due. Same interval as the timer,
    /// no extra timer, and nothing runs while the window is closed.
    func windowOpened() {
        guard launched, config != nil, status != .checking else { return }
        if case .downloading = status { return }
        if case .ready = status { return }
        if status == .installing { return }
        guard UpdatePolicy.isDue(automatic: settings.automatic, lastCheck: settings.lastCheck, now: Date()) else { return }
        runAutomaticCheck()
    }

    /// The new app carries the new tool pins. Its bundled `noodle` re-fetches only Noodle's own
    /// out-of-date copies (SHA-256 checked) and never touches tools installed elsewhere.
    private func refreshManagedTools() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/noodle")
        guard FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.fileExists(atPath: Tools.directory(paths).path) else { return }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["update", "confirm"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Only the explicit settings button bypasses the automatic preference.
    func check(manual: Bool = false) async {
        guard manual || settings.automatic, !Task.isCancelled else { return }
        guard let config, status != .checking, status != .installing else { return }
        if case .downloading = status { return }
        status = .checking
        settings.lastCheck = Date(); try? settings.save(paths)
        defer { scheduleAutomaticCheck() }
        do {
            guard let (feed, url) = try await UpdateClient.check(config) else { status = .upToDate; return }
            try Task.checkCancellation()
            guard manual || settings.automatic else { status = .idle; return }
            status = .downloading(feed.version)
            let zip = try await UpdateClient.download(feed, feedURL: url, into: UpdateStore.downloads(paths))
            let current = Bundle.main.bundleURL, paths = self.paths
            // ditto and codesign --deep take seconds; keep them off the main thread.
            let state = try await Task.detached {
                try UpdateInstaller.stage(zip: zip, feed: feed, current: current, paths: paths)
            }.value
            status = .ready(state.version)
        } catch is CancellationError { status = .idle }
        catch { status = .failed(error.localizedDescription) }
    }

    /// Query at the moment Restart is chosen. Any failure is unknown and requires confirmation.
    func runningContainers(env: AppEnvironment) async -> Int? {
        guard let list = try? await env.service.containers() else { return nil }
        return list.filter(\.isRunning).count
    }

    /// Stop the engine (and stay put if it will not stop), swap the bundle, start the engine again
    /// with the new binary if it was running, open the new copy, quit this one.
    func installAndRestart(env: AppEnvironment) async {
        guard status != .installing else { return }
        guard !env.macMachine.isActive else {
            env.macMachine.error = "Shut down the macOS machine before restarting to update Noodle."
            env.showMainWindow(.macMachine)
            return
        }
        status = .installing
        // The CLI owns the same stop, swap and restart sequence for both entry points. It starts
        // the new bundle's helper only after the old daemon has exited.
        let result = await CLI.run(["update", "install", "--app", Bundle.main.bundleURL.path, "--yes"])
        switch UpdateCommandOutcome(code: result.code, output: result.output) {
        case .failed(let message):
            status = .failed(message)
            await env.sync.refreshNow()
        case .installed(let restartError):
            Relaunch.reopenApp(restartError: restartError)
        }
    }
}

extension Relaunch {
    /// Open a fresh instance of this bundle (after an install or rollback) and quit the running one.
    @MainActor static func reopenApp(restartError: String? = nil) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = ProcessInfo.processInfo.environment["NOODLE_NO_ACTIVATE"] == nil
        var environment = ProcessInfo.processInfo.environment
        environment[UpdateCommandOutcome.restartErrorEnvironmentKey] = restartError
        cfg.environment = environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
