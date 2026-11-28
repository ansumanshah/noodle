import Foundation
import NoodleCore

/// Fixed flows for `--demo-setup --demo-setup-state=<name>` and the self-test renders. No process, VM or network.
/// The numbers and paths here exist only to draw the states; the live flow never uses them.
@MainActor
enum SetupPreview {
    static let names = ["detect", "tools", "tools-all-missing", "tools-downloading", "engine", "engine-other", "import", "first",
                        "done", "fail-network", "fail-disk", "fail-tool", "fail-declined", "fail-docker-missing", "fail-daemon",
                        "fail-import", "stopped-download"]

    static let other = SetupEngine(name: "desktop-linux", socket: "/Users/dev/.docker/run/docker.sock", reachable: true, inUse: true,
                                   inventory: ImportInventory(images: 12, volumes: 3, containers: 0))
    static let orbstack = SetupEngine(name: "orbstack", socket: "/Users/dev/.orbstack/run/docker.sock", reachable: true, inUse: false,
                                      inventory: ImportInventory(images: 4, volumes: 2, containers: 1))

    static func tools(missing: Set<String>) -> [SetupTool] {
        [SetupTool(name: "docker", path: missing.contains("docker") ? nil : "/opt/homebrew/bin/docker",
                   version: missing.contains("docker") ? nil : "29.9.3"),
         SetupTool(name: "docker-compose", path: missing.contains("docker-compose") ? nil : "~/.docker/cli-plugins/docker-compose",
                   version: missing.contains("docker-compose") ? nil : "5.7.1"),
         SetupTool(name: "docker-buildx", path: missing.contains("docker-buildx") ? nil : "~/.docker/cli-plugins/docker-buildx",
                   version: missing.contains("docker-buildx") ? nil : "0.39.0")]
    }

    static func flow(named name: String) -> SetupFlow? {
        guard names.contains(name) else { return nil }
        let backend = ScriptedSetupBackend()
        let flow = SetupFlow(backend: backend)
        let missing: Set<String> = name == "tools-all-missing" || name == "tools-downloading" || name == "fail-docker-missing" || name == "fail-declined"
            ? ["docker", "docker-compose", "docker-buildx"] : ["docker-buildx"]
        let withEngine = ["engine-other", "import", "first", "done", "fail-import"].contains(name)
        flow.detection = SetupDetection(tools: tools(missing: name.hasPrefix("engine") || withEngine ? [] : missing),
                                        engines: withEngine ? [other] : [], shell: "/bin/zsh", pathNeeded: true)
        flow.plan = .make(flow.detection!, sizes: ["docker": 19_641_900])
        flow.useDefault = !withEngine
        flow.terminalPath = backend.terminalPath
        flow.stage = .plan
        switch name {
        case "detect": flow.stage = .detect; flow.detection = nil
        case "tools-downloading":
            flow.stage = .download
            flow.downloads = ["docker": SetupDownload(done: 10_000_000, total: 19_641_900)]
        case "engine", "engine-other": flow.stage = .engine; flow.toolsSkipped = name == "engine"
        case "import":
            flow.detection?.engines.append(orbstack)
            flow.stage = .importChoice
            flow.importOn = true
            flow.selectImportSource(orbstack.name)
        case "first":
            flow.stage = .container; flow.status = "Fetching a small test image…"
            for line in ["9824c27679d3: Pulling fs layer", "abcdef123456: Pulling fs layer", "9824c27679d3: Pull complete"] { flow.pull.ingest(line) }
        case "done":
            flow.stage = .done; flow.milliseconds = 412; flow.transcript = SetupFlow.greeting
            flow.importNote = "Copied 15 items from Docker Desktop."
        case "fail-network": flow.fail(.noNetwork, from: .download)
        case "fail-disk": flow.fail(.diskFull, from: .download)
        case "fail-tool": flow.fail(.brokenTool("docker"), from: .download)
        case "fail-declined": flow.fail(.declined, from: .plan)
        case "fail-docker-missing": flow.fail(.dockerMissing, from: .download)
        case "fail-daemon": flow.fail(.daemonDown, from: .install)
        case "fail-import":
            flow.importOn = true
            flow.fail(.importFailed("1 item didn’t copy. volume pgdata: FAILED the source engine stopped."), from: .importing)
        case "stopped-download":
            flow.fail(.stopped("Any tools already checked and saved stay. No Docker context or shell profile changed. Try Again to finish."), from: .download)
        default: break
        }
        return flow
    }
}
