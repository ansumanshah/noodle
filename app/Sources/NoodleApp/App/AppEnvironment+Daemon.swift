import Foundation

// MARK: - Daemon control (through the CLI) and setup

extension AppEnvironment {
    func startDaemon() async {
        guard !demo, nav.canChangeInstallation, connection.transition == nil, !connection.retryingConnection else { return }
        connection.message = nil
        connection.transition = .starting
        let r = await CLI.run(["start"])
        if r.code != 0 { connection.message = r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        for _ in 0..<20 {
            if (try? await service.ping()) != nil { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        connection.transition = nil
        await sync.refreshNow()
    }

    func stopDaemon() async {
        guard !demo, connection.transition == nil, !connection.retryingConnection else { return }
        connection.message = nil
        connection.transition = .stopping
        let r = await CLI.run(["stop"])
        if r.code != 0 { connection.message = r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        try? await Task.sleep(for: .milliseconds(600))
        connection.transition = nil
        await sync.refreshNow()
        connection.reconnecting = false
    }

    /// Runs `noodle setup` with the flags the setup flow chose. The flow starts and verifies the daemon itself,
    /// because exit 0 alone does not mean `docker` works.
    func runSetup(_ args: [String], run: @MainActor ([String]) async -> CLI.Result = { await CLI.run($0, timeout: 900) }) async -> CLI.Result {
        guard nav.canChangeInstallation else { return .init(code: 1, output: "Wait for the current setup or uninstall to finish.") }
        nav.setupMutationRunning = true
        defer { nav.setupMutationRunning = false }
        if !demo, args.first == "setup", args.contains("--use") {
            let context = await Task.detached { SetupProbe.dockerContexts(ProcessInfo.processInfo.environment).current ?? "default" }.value
            if context != "noodle" { UserDefaults.standard.set(context, forKey: UninstallNoodle.previousContextKey) }
        }
        let r = await run(args)
        connection.setupDone = CLI.isSetUp
        return r
    }

    func setSetupCompleted(_ completed: Bool) {
        connection.setupCompleted = completed
        if !demo { UserDefaults.standard.set(completed, forKey: "setupCompleted") }
    }

    func finishSetup(finished: Bool, previouslyCompleted: Bool) {
        setSetupCompleted(finished || previouslyCompleted)
    }

    func uninstall(using flow: UninstallFlow) async {
        guard nav.canChangeInstallation else { return }
        nav.uninstallRunning = true
        sync.setWindowVisible(false)
        await flow.uninstall()
        nav.uninstallFinished = flow.succeeded
        nav.uninstallRunning = false
        if flow.succeeded {
            connection.setupDone = false
            setSetupCompleted(false)
            if !demo { UserDefaults.standard.removeObject(forKey: UninstallNoodle.previousContextKey) }
        } else {
            MainWindowVisibility.update(env: self)
        }
    }
}
