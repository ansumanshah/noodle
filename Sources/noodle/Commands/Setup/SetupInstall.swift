import Foundation
import NoodleCore

// Setup starts the engine once at the end (unless --no-start); doctor and uninstall start nothing. The LaunchAgent stays RunAtLoad off.
var setupFM: FileManager { .default }
let setupLegacyLabel = "dev.noodleapps.noodled"
let setupReceiptURL = paths.root.appendingPathComponent("setup.json")
let setupBin = URL(fileURLWithPath: home).appendingPathComponent(".local/bin")

func setupLaunchctl(_ args: [String]) -> (code: Int32, out: String) {
    if let seam = env["NOODLE_LAUNCHCTL"], !seam.isEmpty { return run(seam, args) }
    guard launchctlAllowed else { return (0, "launchctl disabled") }
    return run("/bin/launchctl", args)
}

func setupReceipt() -> [String: String] {
    guard let data = try? Data(contentsOf: setupReceiptURL),
          let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return value
}

func setupRecord(_ key: String, _ value: String) throws {
    var receipt = setupReceipt()
    receipt[key] = value
    try setupFM.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try JSONEncoder().encode(receipt).write(to: setupReceiptURL, options: .atomic)
}

func setupRecordLink(_ link: URL, target: String) throws { try setupRecord("link:" + link.path, target) }

func setupOwnedLink(_ link: URL) -> Bool {
    LazyToolPlugin.owns(link, receipt: setupReceipt())
}

/// The retained CLI can still find an installed app through its agent after setup.
func setupDaemonPath() -> String {
    let nearby = noodledPath()
    if setupFM.isExecutableFile(atPath: nearby) { return nearby }
    if let data = try? Data(contentsOf: plistURL),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let program = (plist["ProgramArguments"] as? [String])?.first,
       setupFM.isExecutableFile(atPath: program) { return program }
    return nearby
}

func setupWriteAgent(daemon: String? = nil) throws {
    let daemon = daemon ?? setupDaemonPath()
    var plist: [String: Any] = [
        "Label": agentLabel, "ProgramArguments": [daemon],
        "RunAtLoad": false, "KeepAlive": false, "ProcessType": "Background",
        "AssociatedBundleIdentifiers": ["dev.getnoodle.Noodle"],  // System Settings shows the Noodle name and icon, not a bare binary
        "StandardOutPath": paths.root.appendingPathComponent("noodled.log").path,
        "StandardErrorPath": paths.root.appendingPathComponent("noodled.log").path,
    ]
    var variables: [String: String] = [:]
    if env["NOODLE_HOME"]?.isEmpty == false { variables["NOODLE_HOME"] = paths.root.path }
    if let resources = env["NOODLE_RESOURCES"], !resources.isEmpty {
        variables["NOODLE_RESOURCES"] = (resources as NSString).expandingTildeInPath
    }
    if !variables.isEmpty { plist["EnvironmentVariables"] = variables }
    try setupFM.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
}

func setupRemoveAgent(label: String) throws {
    guard [agentLabel, setupLegacyLabel].contains(label) else { return }
    let target = "gui/\(uid)/\(label)"
    if launchctlAllowed || env["NOODLE_LAUNCHCTL"] != nil, setupLaunchctl(["print", target]).code == 0 {
        let result = setupLaunchctl(["bootout", target])
        guard result.code == 0 else { throw CLIError("cannot unload \(label): \(result.out)") }
    }
    let file = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    if setupFM.fileExists(atPath: file.path) { try setupFM.removeItem(at: file) }
}

private var setupContextDirectory: URL {
    let hash = String(Digest.sha256(Data("noodle".utf8)).dropFirst(7))
    return dockerConfigDirectory.appendingPathComponent("contexts/meta/" + hash)
}

func setupContextFileExists() -> Bool { setupFM.fileExists(atPath: setupContextDirectory.appendingPathComponent("meta.json").path) }

func setupContext() -> [String: Any]? {
    guard let data = try? Data(contentsOf: setupContextDirectory.appendingPathComponent("meta.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func setupOwnsContext(_ context: [String: Any]) -> Bool {
    guard context["Name"] as? String == "noodle" else { return false }
    let metadata = context["Metadata"] as? [String: Any]
    guard metadata?["Description"] as? String == "Noodle" else { return false }
    let endpoint = ((context["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
    return endpoint == "unix://" + socketPath || (endpoint != nil && endpoint == setupReceipt()["context:" + dockerConfigDirectory.path])
}

func setupRepairContext() throws {
    if setupFM.fileExists(atPath: setupContextDirectory.appendingPathComponent("meta.json").path), setupContext() == nil {
        throw CLIError("context noodle metadata is unreadable; preserved")
    }
    if let context = setupContext(), !setupOwnsContext(context) {
        throw CLIError("context noodle belongs to another installation; preserved")
    }
    guard let docker = discoveredDocker() else {
        throw CLIError("Docker CLI unavailable. Run `noodle setup --tools` to download checksum-verified clients.")
    }
    let exists = setupContext() != nil
    let args = ["context", exists ? "update" : "create", "noodle", "--description", "Noodle", "--docker", "host=unix://" + socketPath]
    // Keep context selection entirely separate from creation and repair.
    let result = run(docker, args, extraEnv: dockerEnv)
    guard result.code == 0 else { throw CLIError("cannot configure context noodle: \(result.out)") }
    try setupRecord("context:" + dockerConfigDirectory.path, "unix://" + socketPath)
    note("Docker context: noodle -> unix://\(socketPath)")
}

private func setupCurrentContext() -> String {
    if let override = env["DOCKER_CONTEXT"], !override.isEmpty { return override + " (DOCKER_CONTEXT)" }
    guard let data = try? Data(contentsOf: dockerConfigDirectory.appendingPathComponent("config.json")),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "default" }
    return config["currentContext"] as? String ?? "default"
}

func setupRemoveContext() throws {
    guard let context = setupContext() else { return }
    guard setupOwnsContext(context) else { note("Kept foreign context noodle"); return }
    let configURL = dockerConfigDirectory.appendingPathComponent("config.json")
    if setupFM.fileExists(atPath: configURL.path) {
        let data = try Data(contentsOf: configURL)
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("cannot read Docker configuration; context preserved")
        }
        if config["currentContext"] as? String == "noodle" {
            config.removeValue(forKey: "currentContext")
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL, options: .atomic)
            note("Docker context in use: default")
        }
    }
    try setupFM.removeItem(at: setupContextDirectory)
    note("Removed Docker context noodle")
}

/// Selects `noodle` only when nothing else is in use: the `default` context pointing at a Docker socket nobody answers on.
func setupShouldSelectNoodle(currentContext: String, endpoint: String, pingAnswered: Bool) -> Bool {
    currentContext == "default" && endpoint == "unix:///var/run/docker.sock" && !pingAnswered
}

/// True when something answers `GET /_ping` on the unix socket. Both ends time out after one second.
func setupPing(socket path: String) -> Bool {
    (try? DockerHTTP(socketPath: path, timeout: 1).request("GET", "/_ping")) != nil
}

/// Decides whether plain `noodle setup` selects the context; prints the one-line reason when it does not.
private func setupWantsNoodleContext() -> Bool {
    let current = setupCurrentContext()
    // NOODLE_DEFAULT_DOCKER_SOCKET lets tests point the default endpoint at a socket they control.
    let socketPath = env["NOODLE_DEFAULT_DOCKER_SOCKET"] ?? "/var/run/docker.sock"
    // shortcut: any DOCKER_HOST counts as another engine; refine only if users set it without running one.
    let endpoint = env["DOCKER_HOST"] ?? "unix://" + socketPath
    let answered = current == "default" && endpoint == "unix://" + socketPath && setupPing(socket: socketPath)
    let normalized = endpoint == "unix://" + socketPath ? "unix:///var/run/docker.sock" : endpoint
    if setupShouldSelectNoodle(currentContext: current, endpoint: normalized, pingAnswered: answered) { return true }
    note("Docker context stays on \(current). Run noodle setup --use to switch.")
    return false
}

func setupInstall(_ args: [String]) {
    let allowed: Set<String> = ["--use", "--no-use", "--tools", "--path", "--no-start"]
    guard args.allSatisfy(allowed.contains), !(args.contains("--use") && args.contains("--no-use")) else {
        die("usage: noodle setup [--use|--no-use] [--tools] [--path] [--no-start]", code: 2)
    }
    // A person at a terminal gets aligned rows; anything reading the output gets the plain lines.
    let finish = isatty(STDOUT_FILENO) != 0 && !jsonRequested ? SetupStyle.begin(home: home) : {}
    defer { finish() }
    do {
        try paths.ensureDirectories()
        try setupRemoveAgent(label: setupLegacyLabel)
        try setupWriteAgent()
        if !setupFM.isExecutableFile(atPath: setupDaemonPath()) {
            err("warning: Noodle engine missing at \(setupDaemonPath()); restore the app and run `noodle doctor --fix`.")
        }
        let deferredPlugins = setupClients(prefetch: args.contains("--tools"))
        try setupRepairContext()
        // Decide before selecting, while the previous context is still current.
        let select = args.contains("--use") || (!args.contains("--no-use") && setupWantsNoodleContext())
        if select, let docker = discoveredDocker() {
            let result = run(docker, ["context", "use", "noodle"], extraEnv: dockerEnv)
            guard result.code == 0 else { throw CLIError("cannot select context: \(result.out)") }
        }
        let cli = try setupTerminal(docker: discoveredDocker(), addPath: args.contains("--path"))
        try installPluginStubs(cli: cli, only: deferredPlugins)
        try setupMarkDataFolder()
        note("Docker context currently selected: \(setupCurrentContext())")
        let tryIt = setupCurrentContext() == "noodle" ? "docker run --rm alpine echo hello" : "docker --context noodle run --rm alpine echo hello"
        if args.contains("--no-start") { note("Setup complete. Run `noodle start`, then try: \(tryIt)") }
        else { cmdStart(); note("Setup complete. Try: \(tryIt)") }
    } catch { die(error.localizedDescription) }
}
