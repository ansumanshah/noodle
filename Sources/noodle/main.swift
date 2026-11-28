import Foundation
import NoodleCore

// noodle: Noodle management commands. Foundation + NoodleCore only.

let version = "26.11.8"
let agentLabel = "dev.getnoodle.noodled"   // keep in sync with the desktop launcher
let env = ProcessInfo.processInfo.environment
let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
let paths = CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "__tool-plugin"
    ? NoodlePaths(root: URL(fileURLWithPath: CommandLine.arguments[3])) : NoodlePaths.resolve()
let socketPath = paths.socket.path
let plistURL = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let launchctlAllowed = env["NOODLE_NO_LAUNCHCTL"] == nil

/// Set while a command restyles its own lines for a terminal (`SetupStyle`); nil prints them as they are.
nonisolated(unsafe) var outFilter: ((String) -> Void)?
func out(_ s: String) { if let outFilter { outFilter(s) } else { print(s) } }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
/// Human chatter: stdout as before, but stderr under `--json` so stdout stays one document.
let jsonRequested = ownArguments(Array(CommandLine.arguments.dropFirst())).contains("--json")
func note(_ s: String) { if jsonRequested { err(s) } else { out(s) } }
func die(_ s: String, code: Int32 = 1) -> Never { err("noodle: " + s); exit(code) }

// MARK: process helpers

// MARK: tiny HTTP-over-unix client (blocking)

// MARK: commands

func usage() { out(CommandTable.topLevelHelp(version: version)) }

// MARK: dispatch

let argv = Array(CommandLine.arguments.dropFirst())
// Group help never starts services or changes installation state. Arguments to
// commands such as `debug run ... --help` still belong to the launched program.
let commands = Set(commandGroups.map(\.name)).subtracting(["help"])
let helpFlags = ["--help", "-h", "help"]
if (argv.count == 2 && commands.contains(argv[0]) && helpFlags.contains(argv[1])) ||
    // A bare group prints its help, except groups whose bare form is a command.
    (argv.count == 1 && CommandTable.hasSubcommands(argv[0]) && !["proxy", "link", "names"].contains(argv[0])) ||
    wantsNestedHelp(argv) {
    printGroupHelp(argv[0])
    exit(0)
}
switch argv.first {
case nil, "help", "-h", "--help":
    cmdHelp(Array(argv.dropFirst()))
case "version", "--version":
    switch Array(argv.dropFirst()) {
    case []: out("noodle \(version)")
    case ["--json"]: out(jsonLine(["schemaVersion": 1, "version": version]))
    default: usageDie("usage: noodle version [--json]")
    }
case "setup": cmdSetup(Array(argv.dropFirst()))
case "doctor": cmdDoctor(Array(argv.dropFirst()))
case "tools": cmdTools(Array(argv.dropFirst()))
case "__tool-plugin": cmdToolPlugin(Array(argv.dropFirst()))
case "scan", "sbom": cmdScan(Array(argv.dropFirst()), sbom: argv[0] == "sbom")
case "update": cmdUpdate(Array(argv.dropFirst()))
case "uninstall": cmdUninstall(Array(argv.dropFirst()))
case "status":
    switch Array(argv.dropFirst()) {
    case ["--json"]: cmdStatusJSON()
    case ["--startup"]: cmdStartupStatus()
    case ["--startup", "--json"], ["--json", "--startup"]: cmdStartupStatus(json: true)
    case []: cmdStatus()
    default: usageDie("usage: noodle status [--json|--startup [--json]]")
    }
case "start":
    guard argv.count == 1 else { die("usage: noodle start", code: 2) }
    cmdStart()
case "debug": cmdDebug(Array(argv.dropFirst()))
case "machine": cmdMachine(Array(argv.dropFirst()))
case "stop":
    guard argv.count == 1 else { die("usage: noodle stop", code: 2) }
    cmdStop()
case "builds", "image": cmdBuildCatalog(argv, paths: paths)
case "names": cmdNames(Array(argv.dropFirst()))
case "pod": cmdPod(Array(argv.dropFirst()))
case "dev": cmdDev(Array(argv.dropFirst()))
case "agent": die("noodle agent is not part of this release.", code: 2)
case "container": cmdContainer(Array(argv.dropFirst()))
case "kube": cmdKube(Array(argv.dropFirst()))
case "kubernetes": cmdKubernetes(Array(argv.dropFirst()))
case "memory": cmdMemory(Array(argv.dropFirst()))
case "model": cmdModel(Array(argv.dropFirst()))
case "link": cmdLink(Array(argv.dropFirst()))
case "share": cmdShare(Array(argv.dropFirst()))
case "finder": cmdFinder(Array(argv.dropFirst()))
case "proxy": cmdProxy(Array(argv.dropFirst()))
case "runners": cmdRunners(Array(argv.dropFirst()))
case "migrate-disk": cmdMigrateDisk(Array(argv.dropFirst()))
case "logs": cmdLogs(Array(argv.dropFirst()), paths: paths)
case "diagnostics": cmdDiagnostics(Array(argv.dropFirst()), paths: paths, version: version)
case "import":
    exit(runImport(Array(argv.dropFirst()), destSocket: socketPath, dockerConfig: dockerEnv["DOCKER_CONFIG"] ?? env["DOCKER_CONFIG"] ?? home + "/.docker",
                   tmpRoot: paths.tmpDir, env: env))
default:
    err(CommandTable.topLevelHelp(version: version))
    usageDie("unknown command '\(argv.first ?? "")'. Use docker --context noodle for container, image, build and Compose commands.")
}
