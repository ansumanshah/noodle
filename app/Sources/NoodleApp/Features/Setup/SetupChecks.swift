import AppKit
import Foundation
import NoodleCore
import SwiftUI

/// Headless checks for the setup assistant. Run with: NOODLE_NO_ACTIVATE=1 NoodleApp --setup-self-test
/// Optional: --setup-self-test-out=<dir> keeps a PNG of every state in light and dark.
/// No VM, daemon, network, visible window or Docker is used.
@MainActor
enum SetupChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() -> Int32 {
        _ = NSApplication.shared
        var code: Int32?
        Task { @MainActor in
            do {
                try await all()
                print("PASS setup-happy-path setup-engine-rule setup-import setup-nothing-missing setup-exit-zero-not-trusted "
                    + "setup-download-verified setup-failure-retry setup-container-verdict setup-refused-download "
                    + "setup-unsupported-shell setup-step-marks setup-cancel setup-import-failure setup-override "
                    + "setup-terminal-command setup-path-blocked setup-terminal-resolution setup-context-selection setup-skip-during-apply setup-render-states")
                code = 0
            } catch {
                FileHandle.standardError.write(Data("FAIL setup-self-test: \(error)\n".utf8))
                code = 1
            }
        }
        while code == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return code ?? 1
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func flow(_ configure: (ScriptedSetupBackend) -> Void = { _ in }) -> (SetupFlow, ScriptedSetupBackend) {
        let backend = ScriptedSetupBackend()
        configure(backend)
        return (SetupFlow(backend: backend), backend)
    }

    /// Every tool already on this Mac, so a flow starts at the engine page without downloading.
    static func found(_ backend: ScriptedSetupBackend) {
        backend.detection.tools = SetupPreview.tools(missing: [])
    }

    static func settle(_ flow: SetupFlow) async throws {
        for _ in 0..<300 { if !flow.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(description: "flow never settled at \(flow.stage)")
    }

    /// Waits for a condition the flow reaches on its own task, such as a held step starting.
    static func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(description: "never reached: \(what)")
    }

    private static func all() async throws {
        try await happyPath()
        try await engineRule()
        try await importChoice()
        try await nothingMissing()
        try await exitZeroNotTrusted()
        try await downloadVerified()
        try await failureRetry()
        try await containerVerdict()
        try await refusedDownload()
        try await unsupportedShell()
        try await stepMarks()
        try await cancelDetect()
        try await cancelDownload()
        try await cancelImport()
        try await cancelPull()
        try await importFailure()
        try await overrideWins()
        try await terminalCommand()
        try await pathBlocked()
        try await terminalResolution()
        try contextSelection()
        try await skipDuringApply()
        try renderStates()
    }

    private static func happyPath() async throws {
        let (flow, backend) = flow()
        await flow.detectAll()
        try expect(flow.stage == .plan && flow.plan?.missing.count == 3, "Plan must list all three missing tools")
        try expect(flow.plan?.size(of: "docker") == 27_000_000, "Show the Docker CLI download size")
        try expect(flow.useDefault && flow.pathOn && flow.downloadsNow, "Defaults: Noodle default, Terminal step on, download needed")
        await flow.download()
        try expect(flow.stage == .engine && flow.detection?.dockerMissing == false, "A finished download must land on the engine page")
        // Downloading only downloads. The agent, context, links and PATH wait for the apply step.
        try expect(backend.installArgs == ["tools", "install", "--no-link", "docker"],
                   "The download step must not configure anything: \(backend.installArgs)")
        flow.continueFromEngine()
        try await settle(flow)
        try expect(backend.installArgs == ["setup", "--path", "--use"], "Apply flags wrong: \(backend.installArgs)")
        try expect(flow.stage == .done && flow.milliseconds == 412 && flow.transcript == SetupFlow.greeting, "Must end at done with time and output: \(flow.stage) \(String(describing: flow.milliseconds)) \(flow.transcript) \(String(describing: flow.problem))")
        try expect(backend.calls == ["detect", "sizes", "install", "detect", "install", "start", "pull", "run", "compose"], "Order: \(backend.calls)")
        try expect(flow.firstCommand == "docker run --rm alpine echo \"Hello from Noodle\"", "Wrong command: \(flow.firstCommand)")
    }

    private static func engineRule() async throws {
        let (flow, backend) = flow { found($0); $0.detection.engines = [SetupPreview.other] }
        await flow.detectAll()
        try expect(!flow.useDefault && flow.defaultReason == "Docker Desktop is your current engine. It stays untouched.",
                   "Default engine must be off with a reason when another engine is in use")
        try expect(flow.currentEngine?.displayName == "Docker Desktop", "The current engine must be named")
        flow.continueFromTools()
        try expect(flow.stage == .engine, "Nothing to download means straight to the engine page")
        flow.continueFromEngine()
        try expect(flow.stage == .importChoice, "A running engine with items must lead to the import page")
        flow.importOn = false
        flow.continueFromImport()
        try await settle(flow)
        try expect(backend.installArgs.last == "--no-use", "Off must pass --no-use")
        try expect(flow.firstCommand.contains("--context noodle"), "Command must name the context when Noodle is not default")
    }

    private static func importChoice() async throws {
        let (flow, backend) = flow { found($0); $0.detection.engines = [SetupPreview.other] }
        await flow.detectAll(); flow.continueFromTools(); flow.continueFromEngine()
        try expect(!flow.importOn, "Import must stay off until it is chosen")
        flow.importOn = true
        flow.continueFromImport()
        try await settle(flow)
        try expect(flow.stage == .done && backend.calls.contains("import:desktop-linux"), "Import must run for the chosen source")
        try expect(backend.importFlags == ["--images", "--volumes"], "Only kinds present in the inventory should be copied")
        try expect(flow.importNote == "Copied 3 items from Docker Desktop.", "The note must use the CLI's real counts: \(flow.importNote ?? "nil")")
        let (selective, selectedBackend) = self.flow {
            found($0)
            $0.detection.engines = [SetupPreview.other, SetupPreview.orbstack]
        }
        await selective.detectAll(); selective.continueFromEngine()
        try expect(selective.importEngine?.name == "desktop-linux", "Prefer the current engine")
        selective.selectImportSource("orbstack")
        selective.importOn = true
        selective.importKinds = []
        selective.continueFromImport()
        try expect(selective.stage == .importChoice, "Require at least one kind before importing")
        selective.importKinds = [.volumes]
        selective.continueFromImport()
        try await settle(selective)
        try expect(selectedBackend.calls.contains("import:orbstack") && selectedBackend.importFlags == ["--volumes"],
                   "Import exactly the selected source and kinds")
        // A conflict the CLI skipped is not reported as copied.
        let (skippedOnly, _) = self.flow { found($0); $0.detection.engines = [SetupPreview.other]
            $0.importResult = CLI.Result(code: 0, output: "done: 0 copied, 1 unchanged or skipped, 0 failed") }
        await skippedOnly.detectAll(); skippedOnly.importOn = true; await skippedOnly.install()
        try expect(skippedOnly.importNote == "Nothing new to copy from Docker Desktop. 1 was already there or skipped.",
                   "A skipped item must not read as copied: \(skippedOnly.importNote ?? "nil")")
        let (skipped, quiet) = self.flow { found($0); $0.detection.engines = [SetupPreview.other] }
        await skipped.detectAll(); skipped.importOn = false; await skipped.install()
        try expect(!quiet.calls.contains { $0.hasPrefix("import:") }, "Skip must not import")
        let stopped = SetupEngine(name: "colima", socket: "/s", reachable: false, inUse: false, inventory: ImportInventory(images: 4))
        let (idle, none) = self.flow { found($0); $0.detection.engines = [stopped] }
        await idle.detectAll(); idle.continueFromTools(); idle.continueFromEngine()
        try await settle(idle)
        try expect(idle.stage == .done && idle.steps.count == 3 && !none.calls.contains { $0.hasPrefix("import:") },
                   "An engine that is not running must not be offered or started")
    }

    private static func nothingMissing() async throws {
        let (flow, backend) = flow { found($0); $0.detection.pathNeeded = false }
        await flow.detectAll()
        try expect(flow.plan?.needsDownload == false && !flow.pathOn && !flow.downloadsNow, "Nothing to download and no PATH step")
        await flow.install()
        try expect(backend.installArgs == ["setup", "--use"] && !backend.calls.contains("sizes"), "Reusing tools must not pass --tools: \(backend.installArgs)")
    }
}
