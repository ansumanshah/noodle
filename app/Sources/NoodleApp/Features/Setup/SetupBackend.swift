import Foundation
import NoodleCore

/// Everything the setup flow needs from the machine. The live one runs the real CLI and Docker;
/// the scripted one (demo and self-test) answers from a fixture with no process, VM or network.
@MainActor
protocol SetupBackend: AnyObject {
    /// Where the `noodle` command lives, for people who prefer the terminal.
    var terminalPath: String { get }
    func detect() async -> SetupDetection
    func sizes(of names: [String]) async -> [String: Int64]
    func install(_ args: [String]) async -> CLI.Result
    /// Sizes of download files currently in Noodle's work folder, by file name.
    func downloadedFiles() -> [String: Int64]
    /// Removes what a cancelled download left in the work folder.
    func discardPartialDownloads()
    func startAndVerify(wantsPath: Bool, waiting: @MainActor (SetupApplyWait) -> Void) async -> SetupFacts
    func runImport(_ source: String, flags: [String]) async -> CLI.Result
    func pull(onLine: @escaping @Sendable (String) -> Void) async -> CLI.Result
    func runContainer() async -> (result: CLI.Result, milliseconds: Int)
    func checkCompose() async -> CLI.Result
}

/// Canned answers. Every field can be changed per check to walk one path through the flow.
@MainActor
final class ScriptedSetupBackend: SetupBackend {
    var detection = SetupDetection(tools: [
        SetupTool(name: "docker", path: nil), SetupTool(name: "docker-compose", path: nil),
        SetupTool(name: "docker-buildx", path: nil),
    ], engines: [], shell: "/bin/zsh", pathNeeded: true)
    /// The tools a successful download leaves on this Mac.
    var toolsAfterDownload = [
        SetupTool(name: "docker", path: "/Users/dev/.noodle/tools/docker", version: "29.9.3"),
        SetupTool(name: "docker-compose", path: "/Users/dev/.noodle/tools/cli-plugins/docker-compose", version: "5.7.1"),
        SetupTool(name: "docker-buildx", path: "/Users/dev/.noodle/tools/cli-plugins/docker-buildx", version: "0.39.0"),
    ]
    var sizeTable: [String: Int64] = ["docker": 27_000_000, "docker-compose": 31_000_000, "docker-buildx": 24_000_000]
    var installResult = CLI.Result(code: 0, output: "Setup complete.")
    var facts = SetupFacts(dockerPath: "/Users/dev/.noodle/tools/docker", daemonUp: true, dockerReachesNoodle: true)
    var importResult = CLI.Result(code: 0, output: "done: 3 copied, 0 unchanged or skipped, 0 failed")
    var pullLines = ["latest: Pulling from library/alpine", "9824c27679d3: Pulling fs layer", "9824c27679d3: Pull complete",
                     "Status: Downloaded newer image for alpine:latest"]
    var pullResult = CLI.Result(code: 0, output: "")
    var containerResult = CLI.Result(code: 0, output: "Hello from Noodle\n")
    var containerMilliseconds = 412
    var composeResult = CLI.Result(code: 0, output: "Docker Compose version v5.7.0")
    private(set) var calls: [String] = []
    private(set) var installArgs: [String] = []
    private(set) var importFlags: [String] = []

    let terminalPath = "~/.local/bin/noodle"
    /// Set false to model a download that exits 0 but leaves nothing usable.
    var downloadWorks = true
    private(set) var allInstallArgs: [[String]] = []

    /// Steps that stay busy until the flow cancels them: "download", "import" or "pull". Lets a check stop work mid-run.
    var hold: Set<String> = []

    /// Waits like a slow tool would, and reports a cancelled run the way the real runner does.
    private func slow(_ step: String) async -> CLI.Result? {
        guard hold.contains(step) else { return nil }
        while hold.contains(step) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return Task.isCancelled ? CLI.Result(code: 130, output: "Command cancelled.") : nil
    }

    func detect() async -> SetupDetection { calls.append("detect"); _ = await slow("detect"); return detection }
    func sizes(of names: [String]) async -> [String: Int64] { calls.append("sizes"); return sizeTable.filter { names.contains($0.key) } }
    func install(_ args: [String]) async -> CLI.Result {
        calls.append("install"); installArgs = args; allInstallArgs.append(args)
        let downloads = args.contains("--tools") || args.starts(with: ["tools", "install"])
        if downloads, let cancelled = await slow("download") { return cancelled }
        if !downloads, let cancelled = await slow("install") { return cancelled }
        if downloads, installResult.code == 0, downloadWorks {
            detection.tools = detection.tools.map { tool in
                guard args.contains("--tools") || args.contains(tool.name) else { return tool }
                return toolsAfterDownload.first { $0.name == tool.name } ?? tool
            }
        }
        return installResult
    }
    func downloadedFiles() -> [String: Int64] { [:] }
    func discardPartialDownloads() { calls.append("discard") }
    func startAndVerify(wantsPath: Bool, waiting: @MainActor (SetupApplyWait) -> Void) async -> SetupFacts {
        calls.append("start")
        waiting(.socket)
        _ = await slow("socket")
        waiting(.dockerVersion)
        _ = await slow("docker-version")
        var result = facts
        result.pathApplied = wantsPath ? (facts.pathApplied ?? true) : nil
        return result
    }
    func runImport(_ source: String, flags: [String]) async -> CLI.Result {
        calls.append("import:\(source)")
        importFlags = flags
        if let cancelled = await slow("import") { return cancelled }
        return importResult
    }
    func pull(onLine: @escaping @Sendable (String) -> Void) async -> CLI.Result {
        calls.append("pull")
        pullLines.forEach(onLine)
        if let cancelled = await slow("pull") { return cancelled }
        return pullResult
    }
    func runContainer() async -> (result: CLI.Result, milliseconds: Int) {
        calls.append("run")
        return (containerResult, containerMilliseconds)
    }
    func checkCompose() async -> CLI.Result {
        calls.append("compose")
        if let cancelled = await slow("compose") { return cancelled }
        return composeResult
    }
}
