import Foundation
import NoodleCore

/// Failure and verdict checks: exit codes are not trusted, and each cause lands on its own page.
extension SetupChecks {
    static func exitZeroNotTrusted() async throws {
        for (facts, expected) in [
            (SetupFacts(dockerPath: nil, daemonUp: true, dockerReachesNoodle: false), SetupProblem.dockerMissing),
            (SetupFacts(dockerPath: "/d", daemonUp: false, dockerReachesNoodle: false), .daemonDown),
            (SetupFacts(dockerPath: "/d", daemonUp: true, dockerReachesNoodle: false), .brokenTool("The Docker command")),
        ] {
            let (flow, backend) = flow { found($0); $0.facts = facts }
            await flow.detectAll(); await flow.install()
            try expect(flow.stage == .failed && flow.problem == expected, "Exit 0 with \(expected) must fail, got \(flow.stage)")
            try expect(!backend.calls.contains("pull") && flow.current == .first, "A failed install stays on the first-container page")
        }
        let (flow, _) = flow { found($0); $0.facts.pathApplied = false }
        await flow.detectAll(); await flow.install()
        try expect(flow.problem == .pathNotApplied, "A Terminal step that did not apply must fail")
    }

    static func downloadVerified() async throws {
        let (flow, _) = flow { $0.downloadWorks = false }
        await flow.detectAll(); await flow.download()
        try expect(flow.stage == .failed && flow.problem == .dockerMissing && flow.failedFrom == .download && flow.current == .tools,
                   "A download that exits 0 but leaves no docker must fail on the tools page")
    }

    static func failureRetry() async throws {
        let (flow, backend) = flow { $0.installResult = CLI.Result(code: 1, output: "noodle: download failed for docker: curl: (6) Could not resolve host") }
        await flow.detectAll(); await flow.download()
        try expect(flow.problem == .noNetwork && flow.failedFrom == .download && flow.mark(.tools) == .failed, "Network failure must map to noNetwork on the tools step")
        backend.installResult = CLI.Result(code: 0, output: "Setup complete.")
        flow.retry()
        try await settle(flow)
        try expect(flow.stage == .engine, "Try Again must finish the download once the cause is gone, got \(flow.stage)")
        let (disk, _) = self.flow { $0.installResult = CLI.Result(code: 1, output: "noodle: cannot install docker: No space left on device") }
        await disk.detectAll(); await disk.download()
        try expect(disk.problem == .diskFull, "Full disk must map to diskFull")
    }

    static func containerVerdict() async throws {
        let (silent, _) = flow { found($0); $0.containerResult = CLI.Result(code: 0, output: "") }
        await silent.detectAll(); await silent.install()
        try expect(silent.stage == .failed && silent.failedFrom == .container, "A container that prints nothing must not count as working")
        let (offline, _) = flow { found($0); $0.pullResult = CLI.Result(code: 1, output: "dial tcp: lookup registry-1.docker.io: no such host") }
        await offline.detectAll(); await offline.install()
        try expect(offline.problem == .noNetwork, "A failed first pull offline must map to noNetwork")
        offline.retry()
        try await settle(offline)
        try expect(offline.stage == .failed, "Retry re-runs the container and fails again while offline")
    }

    static func refusedDownload() async throws {
        let (flow, backend) = flow()
        await flow.detectAll(); flow.declineDownload()
        try expect(flow.problem == .declined && flow.stage == .failed && flow.current == .tools, "Refusing the download must say what to do")
        flow.retry()
        try await settle(flow)
        try expect(flow.stage == .plan && backend.calls.filter { $0 == "detect" }.count == 2, "Try Again after a refusal must look again")
    }

    static func unsupportedShell() async throws {
        let (flow, backend) = flow { found($0); $0.detection.shell = "/opt/homebrew/bin/fish" }
        await flow.detectAll()
        try expect(!flow.pathOn && !flow.pathSupported, "Unsupported shell must turn the Terminal step off")
        await flow.install()
        try expect(!backend.installArgs.contains("--path") && flow.pathReminder == SetupPlan.pathLine, "No --path for fish, and the line is shown instead")
    }

    static func stepMarks() async throws {
        let (flow, _) = flow { found($0); $0.detection.engines = [SetupPreview.other] }
        await flow.detectAll()
        try expect(flow.steps.map(\.title) == ["Docker Tools", "Default Engine", "Import", "First Container"], "Four steps with an engine to import from")
        try expect(flow.toolsSkipped && flow.stage == .engine, "Tools already found: the tools step is skipped without asking")
        try expect(flow.mark(.tools) == .done && flow.mark(.engine) == .current && flow.mark(.first) == .upcoming, "Engine page lights Default Engine")
        try expect(flow.header.detail == SetupFlow.reassurance && flow.foundSummary == "Found docker, compose and buildx", "Skipped tools: reassurance and one found line")
        flow.continueFromTools(); flow.continueFromEngine()
        try expect(flow.mark(.tools) == .done && flow.mark(.engine) == .done && flow.mark(.importItems) == .current, "Import page lights Import")
        await flow.install()
        try expect(flow.steps.allSatisfy { flow.mark($0) == .done }, "Done marks every step")
    }
}
