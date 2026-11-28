import Foundation
import NoodleCore

/// Checks for stopping work, import failures, overrides that beat the chosen default, and the terminal alternative.
extension SetupChecks {
    private static let imported = CLI.Result(code: 0, output: "done: 3 copied, 0 unchanged or skipped, 0 failed")
    private static let importFailedResult = CLI.Result(code: 1, output: "volume data: FAILED boom\ndone: 2 copied, 0 unchanged or skipped, 1 failed")

    private static func withEngine(_ configure: @escaping (ScriptedSetupBackend) -> Void = { _ in }) -> (SetupFlow, ScriptedSetupBackend) {
        flow { found($0); $0.detection.engines = [SetupPreview.other]; configure($0) }
    }

    /// Detection only reads, so stopping it changes nothing.
    static func cancelDetect() async throws {
        let (flow, _) = flow()
        flow.begin()
        try expect(flow.cancellable, "Detection must be stoppable")
        flow.stopWork()
        try await until("detection stopped") { !flow.stopping }
        try await Task.sleep(for: .milliseconds(60))
        try expect(flow.detection == nil && flow.stage == .detect && flow.problem == nil, "Stopping detection must change nothing")
        let (applying, _) = self.flow()
        applying.stage = .install
        try expect(!applying.cancellable, "Applying the choices is never cut short")
        applying.stopWork()
        try expect(applying.stage == .install, "Stop does nothing while applying")
    }

    static func cancelDownload() async throws {
        let (flow, backend) = flow { $0.hold = ["download"] }
        await flow.detectAll()
        flow.continueFromTools()
        try await until("download running") { backend.calls.last == "install" }
        try expect(flow.stage == .download && flow.cancellable, "A running download must be stoppable")
        flow.stopWork()
        try expect(flow.stopping, "Retry must wait for the cancelled process to finish")
        try await until("download stopped") { !flow.stopping }
        try expect(flow.stage == .failed && flow.failedFrom == .download && flow.current == .tools, "Stopping stays on the tools page")
        guard case .stopped(let remains)? = flow.problem else { throw Failure(description: "A stopped download must say so: \(String(describing: flow.problem))") }
        try expect(remains.contains("Any tools already checked and saved stay") && remains.contains("No Docker context or shell profile changed"),
                   "The page must say what remains: \(remains)")
        try await until("partial download discarded") { backend.calls.contains("discard") }
        // Only the download ran: no agent, context, links or PATH were applied.
        try expect(backend.allInstallArgs.allSatisfy { $0.first == "tools" } && !backend.calls.contains("start"),
                   "A stopped download must leave nothing configured: \(backend.allInstallArgs)")
        backend.hold = []
        flow.retry()
        try await settle(flow)
        try expect(flow.stage == .engine, "Try Again after stopping must finish the download, got \(flow.stage)")
    }

    static func cancelImport() async throws {
        let (flow, backend) = withEngine { $0.hold = ["import"] }
        await flow.detectAll(); flow.continueFromTools(); flow.continueFromEngine()
        flow.importOn = true
        flow.continueFromImport()
        try await until("import running") { backend.calls.last == "import:desktop-linux" }
        try expect(flow.stage == .importing && flow.cancellable, "A running import must be stoppable")
        flow.stopWork()
        try await until("import stopped") { !flow.stopping }
        try expect(flow.stage == .failed && flow.failedFrom == .importing && flow.current == .importItems, "Stopping stays on the Import step")
        try expect(flow.mark(.importItems) == .failed && flow.header.title == "You stopped setup", "The Import step must say it was stopped")
        try expect(flow.header.detail.contains("nothing was removed from Docker Desktop"), "It must say what remains: \(flow.header.detail)")
        try expect(!flow.header.detail.contains("unfinished volume") && flow.header.detail.contains("Cleanup may be incomplete"),
                   "Stopping must not promise cleanup or prescribe removing an unfinished volume")
        try expect(!backend.calls.contains("pull"), "A stopped import must not go on to the test container")
        backend.hold = []
        flow.skipImport()
        try await settle(flow)
        try expect(flow.stage == .done && flow.importNote == "Import skipped. To copy later, run noodle import 'desktop-linux' --all.",
                   "Skip for Now must go on and say how to finish: \(flow.importNote ?? "nil")")
    }

    static func cancelPull() async throws {
        let (flow, backend) = flow { found($0); $0.hold = ["pull"] }
        await flow.detectAll(); flow.continueFromTools(); flow.continueFromEngine()
        try await until("pull running") { flow.pulling }
        try expect(flow.cancellable, "The pull must be stoppable")
        flow.stopWork()
        try await until("pull stopped") { !flow.stopping }
        try expect(flow.stage == .failed && flow.failedFrom == .container && !flow.pulling, "Stopping the pull stays on the first container page")
        try expect(flow.header.detail.hasPrefix("Noodle is set up."), "It must say Noodle is already set up: \(flow.header.detail)")
        try expect(!backend.calls.contains("run"), "A stopped pull must not run the container")
        backend.hold = []
        flow.retry()
        try await settle(flow)
        try expect(flow.stage == .done, "Try Again after stopping the pull must finish, got \(flow.stage)")
    }

    /// An import that fails keeps its cause on the Import step, with Try Again and Skip for Now.
    static func importFailure() async throws {
        let (flow, backend) = withEngine { $0.importResult = importFailedResult }
        await flow.detectAll(); flow.importOn = true; await flow.install()
        try expect(flow.stage == .failed && flow.failedFrom == .importing && flow.current == .importItems, "A failed import stays on the Import step")
        try expect(flow.problem == .importFailed("1 item didn’t copy. volume data: FAILED boom"), "The cause must be kept: \(String(describing: flow.problem))")
        try expect(flow.header.detail.contains("Nothing was removed"), "It must say nothing was removed")
        try expect(!backend.calls.contains("pull"), "The test container must wait for the import")
        backend.importResult = imported
        flow.retry()
        try await settle(flow)
        try expect(flow.stage == .done && flow.importNote == "Copied 3 items from Docker Desktop.", "Try Again must finish: \(flow.importNote ?? "nil")")
        let (skipped, other) = withEngine { $0.importResult = importFailedResult }
        await skipped.detectAll(); skipped.importOn = true; await skipped.install()
        skipped.skipImport()
        try await settle(skipped)
        try expect(skipped.stage == .done && other.calls.contains("pull"), "Skip for Now must go on to the test container")
    }

    /// DOCKER_CONTEXT or DOCKER_HOST beat the saved default, so the command names the context.
    static func overrideWins() async throws {
        let (flow, _) = flow { found($0); $0.detection.dockerOverride = "DOCKER_CONTEXT" }
        await flow.detectAll(); await flow.install()
        try expect(flow.useDefault && flow.firstCommand == "docker --context noodle run --rm alpine echo \"Hello from Noodle\"",
                   "An override must put --context noodle in the command: \(flow.firstCommand)")
        try expect(flow.overrideNote == "DOCKER_CONTEXT is set, so plain docker still uses that engine. Unset it to use Noodle by default.",
                   "An override must be explained: \(flow.overrideNote ?? "nil")")
        let (plain, _) = self.flow { found($0) }
        await plain.detectAll()
        try expect(plain.overrideNote == nil && !plain.firstCommand.contains("--context"), "No override, no context flag")
    }

    /// The terminal alternative carries the flags that work on this Mac, and the first page says what changes.
    static func terminalCommand() async throws {
        let cli = "~/.local/bin/noodle"
        let (missing, _) = flow()
        await missing.detectAll()
        try expect(missing.terminalCommand == "\(cli) setup --path --use", "Plain setup fetches Docker automatically: \(missing.terminalCommand)")
        missing.pathOn = false; missing.useDefault = false
        try expect(missing.terminalCommand == "\(cli) setup --no-use", "Choices must show: \(missing.terminalCommand)")
        let (have, _) = flow { found($0) }
        await have.detectAll()
        try expect(have.terminalCommand == "\(cli) setup --path --use", "Nothing to download means no --tools: \(have.terminalCommand)")
        try expect(SetupChangesLine.summary.split(separator: " ").count < 12 && !SetupChangesLine.details.joined().contains("—"),
                   "The first page says what changes in under 12 words")
    }

    static func pathBlocked() async throws {
        let (flow, _) = flow { found($0); $0.facts.pathApplied = true; $0.facts.pathConflict = "~/.local/bin/docker" }
        await flow.detectAll(); await flow.install()
        try expect(flow.stage == .failed && flow.problem == .pathBlocked("~/.local/bin/docker"),
                   "A docker file that does not run ahead on PATH must fail: \(String(describing: flow.problem))")
    }
}
