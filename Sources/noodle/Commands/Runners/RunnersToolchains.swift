import Foundation
import NoodleCore

/// The PATH a macOS job gets. The probes use it too, so they see what a job sees.
let macJobPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"

private let probeTimeout = 3.0

/// (name, executable, arguments). Resolved in the job PATH by file lookup only, so nothing is run to find it.
private let probes: [(name: String, exe: String, args: [String])] = [
    ("Swift", "swift", ["--version"]), ("Node", "node", ["--version"]), ("Bun", "bun", ["--version"]),
    ("Python", "python3", ["--version"]), ("Rust", "rustc", ["--version"]), ("Cargo", "cargo", ["--version"]),
    ("Go", "go", ["version"]), ("Ruby", "ruby", ["--version"]), ("CocoaPods", "pod", ["--version"]),
    ("Docker", "docker", ["--version"]),
]

private final class Locked: @unchecked Sendable {
    let lock = NSLock()
    var probes: [String: Toolchains.Probe]
    init(_ probes: [String: Toolchains.Probe]) { self.probes = probes }
}

private func jobExecutable(_ name: String) -> String? {
    macJobPath.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func xcodeVersion(app: String) -> String? {
    let plist = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
    return plist?["CFBundleShortVersionString"] as? String
}

/// Installed Xcodes (version only, read from Info.plist) and the selected one, when `xcode-select` has one.
private func xcodes() -> (selected: String?, others: [String], developerDir: String?, probeFailed: Bool) {
    let jobEnv = ["PATH": macJobPath, "HOME": home]
    let r = runWithTimeout("/usr/bin/xcode-select", ["-p"], environment: jobEnv, timeout: probeTimeout)
    let dir = r.code == 0 && !r.out.isEmpty ? r.out : nil
    let selectedApp = dir.flatMap { d in d.range(of: ".app/").map { String(d[..<$0.lowerBound]) + ".app" } }
    let selected = selectedApp.flatMap(xcodeVersion(app:))
    let apps = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
    let all = Set(apps.compactMap { xcodeVersion(app: "/Applications/" + $0) })
    return (selected, all.subtracting([selected].compactMap { $0 }).sorted(), dir, r.code == 124 || r.code == 127)
}

/// The selected Xcode's major version, from `xcode-select -p` and the app's Info.plist. Never runs xcodebuild, which
/// opens the Command Line Tools dialog when nothing is selected. Nil with only the Command Line Tools selected.
/// The selected Xcode's major version; nil when `xcode-select` timed out or could not run, so a caller keeps what it knew.
func selectedXcodeMajor() -> String?? {
    let x = xcodes()
    if x.probeFailed { return nil }
    return .some(x.selected.flatMap { Toolchains.xcodeMajor(ToolchainInventory(tools: ["Xcode": $0])) })
}

/// Shims in /usr/bin that open the Command Line Tools install dialog when no developer folder is selected.
private let developerShims: Set<String> = ["swift", "python3"]

func probeToolchains() -> ToolchainInventory {
    let x = xcodes()
    let previous = runnerStore.toolchains()?.inventory.tools ?? [:]
    let found = Locked([:])
    DispatchQueue.concurrentPerform(iterations: probes.count) { i in
        let p = probes[i]
        var result = Toolchains.Probe.absent
        if let exe = jobExecutable(p.exe), !(exe.hasPrefix("/usr/bin/") && developerShims.contains(p.exe) && x.developerDir == nil) {
            // Stdout only: a warning on stderr (a shim, a deprecation) can hold a number that is not the version.
            let r = runWithTimeout(exe, p.args, environment: ["PATH": macJobPath, "HOME": home, "LANG": "en_US.UTF-8"], timeout: probeTimeout,
                                   errorOutput: FileHandle.nullDevice)
            result = r.code == 0 ? Toolchains.version(tool: p.name, from: r.out).map(Toolchains.Probe.version) ?? .unknown : .unknown
        }
        found.lock.withLock { found.probes[p.name] = result }
    }
    var tools = Toolchains.resolve(found.probes, previous: previous)
    if let xcode = x.selected { tools["Xcode"] = xcode }
    return ToolchainInventory(tools: tools, otherXcodes: x.others)
}

/// At a macOS runner start: refresh the stored snapshot at most every `Toolchains.refreshSeconds`, off the job loop.
func recordToolchainsInBackground() {
    if runnerStore.toolchains()?.isFresh(at: Date()) == true { return }
    DispatchQueue.global(qos: .utility).async {
        let snapshot = ToolchainSnapshot.recorded(previous: runnerStore.toolchains(), now: probeToolchains(), at: Date())
        try? runnerStore.saveToolchains(snapshot)
    }
}

/// Changes since the last job: live inventory against the stored one, else what the last job start saw.
func toolchainChanges(live: ToolchainInventory) -> [String] {
    guard let stored = runnerStore.toolchains() else { return [] }
    let now = Toolchains.changes(from: stored.inventory, to: live)
    if !now.isEmpty { return now }
    return Toolchains.visibleChanges(stored, lastMacJob: runnerStore.state().history?.first { $0.kind == .macos }?.at)
}

func runnersToolchains(json: Bool) {
    let live = probeToolchains()
    let changes = toolchainChanges(live: live)
    let labels = RunnerLabels.macos(xcodeMajor: Toolchains.xcodeMajor(live))
    if json {
        var object: [String: Any] = ["schemaVersion": 1, "tools": live.tools, "otherXcodes": live.otherXcodes, "changes": changes, "labels": labels]
        if let at = runnerStore.toolchains()?.at { object["lastJobSnapshot"] = ISO8601DateFormatter().string(from: at) }
        jsonOut(object)
        return
    }
    for name in Toolchains.order {
        guard let v = live.tools[name] else { continue }
        out("\(name) \(v)" + (name == "Xcode" && !live.otherXcodes.isEmpty ? " (selected; also installed: \(live.otherXcodes.joined(separator: ", ")))" : ""))
    }
    if live.tools.isEmpty { out("No build tools found on the job PATH.") }
    out("Labels: " + labels.joined(separator: ", "))
    if !changes.isEmpty {
        out("")
        changes.forEach { out("\($0) since the last job") }
    }
}

/// One line for `runners status`, or nil. Reads only what the last job start stored; no tool is run.
func toolchainStatusLine() -> String? {
    let lastMac = runnerStore.state().history?.first { $0.kind == .macos }?.at
    let changes = Toolchains.visibleChanges(runnerStore.toolchains(), lastMacJob: lastMac)
    return changes.isEmpty ? nil : "Toolchains changed since the last job: " + changes.joined(separator: ", ")
}
