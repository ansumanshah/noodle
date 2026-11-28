import Foundation
import Darwin
import NoodleCore

// noodle tools: checked first-use download of the pinned Docker client tools. Nothing global:
// files go to <NOODLE_HOME>/tools, and cli-plugins links are added to the Docker config only for
// names that are absent (Docker Desktop's own links and user binaries are never replaced).

let toolsDirectory = Tools.directory(paths)
let dockerConfigDirectory = URL(fileURLWithPath: env["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.docker")

/// The docker CLI to use when none is on PATH: one found on this Mac (Homebrew, mise, a Docker
/// config) or Noodle's downloaded copy. Nil when neither works, so callers print their install hint.
func bundledDocker() -> String? { discoveredDocker() }

func toolFileOK(_ url: URL, sha: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.path) && (try? Digest.sha256(file: url)) == "sha256:" + sha
}

func cmdTools(_ args: [String]) {
    switch args.first {
    case "install":
        // Optional tool names limit the download, so setup can fetch only what this Mac lacks.
        let names = Set(args.dropFirst().filter { $0 != "--no-link" })
        let known = Set(Tools.pins.map(\.name) + Tools.extras.map(\.name) + Tools.pluginNames + [BuildKitAdapter.toolName])
        guard names.isSubset(of: known) else { die("usage: noodle tools install [--no-link] [\(known.sorted().joined(separator: " | "))]", code: 2) }
        toolsInstall(names: names.isEmpty ? nil : names, link: !args.contains("--no-link"))
    case "status", "remove":
        guard args.count == 1 || (args.count == 2 && args == ["status", "--json"]) else { usageDie("usage: noodle tools status [--json] | remove") }
        if args[0] == "status" { toolsStatus(json: args.contains("--json")) } else { toolsRemove() }
    default: die("usage: noodle tools install [--no-link] [name...] | status [--json] | remove", code: 2)
    }
}

/// Work folders left by a download that was killed. A live download's folder is never touched.
func toolsClearStaleDownloads() {
    let fm = FileManager.default
    for dir in (try? fm.contentsOfDirectory(atPath: toolsDirectory.path)) ?? [] where dir.hasPrefix(".download-") {
        guard let owner = pid_t(dir.dropFirst(".download-".count)), kill(owner, 0) != 0, errno == ESRCH else { continue }
        try? fm.removeItem(at: toolsDirectory.appendingPathComponent(dir))
    }
}

/// Download the pinned tools. `names` limits it to those tools (setup found the rest on this Mac).
/// Plugin caches are reused only after verifying their hash, including during explicit prefetch.
/// Every download is checked before any tool is installed. An interrupted commit can retain
/// complete verified tools, never a partially copied executable.
func toolsInstall(names: Set<String>? = nil, link: Bool = true, lazy: Bool = false, lazyLink: URL? = nil, handoff: (() -> Void)? = nil) {
    let fm = FileManager.default
    let installLock: ToolInstallLock
    do { installLock = try ToolInstallLock(paths: paths) }
    catch { die("cannot lock tools installation: \(error.localizedDescription)") }
    defer { withExtendedLifetime(installLock) {} }
    func progress(_ message: String) { if lazy { err(message) } else { note(message) } }
    let mirror = env["NOODLE_TOOLS_MIRROR"].flatMap { $0.isEmpty ? nil : $0 }
    let plugins = Tools.pluginDirectory(paths)
    do { try fm.createDirectory(at: plugins, withIntermediateDirectories: true) } catch { die("cannot create \(plugins.path): \(error.localizedDescription)") }
    toolsClearStaleDownloads()
    let work = toolsDirectory.appendingPathComponent(".download-\(getpid())")
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    func bail(_ m: String) -> Never {
        try? fm.removeItem(at: work)
        let hint = names?.sorted().joined(separator: " ") ?? ""
        die(m + (lazy ? ". Check the connection or run `noodle tools install \(hint)` before retrying." : ""))
    }
    var ready: [(pin: ToolPin, staged: URL, final: URL, marker: URL)] = []
    for pin in Tools.pins + Tools.extras {
        let extra = Tools.extras.contains(pin)
        if extra ? !(names?.contains(pin.name) ?? false) : !(names?.contains(pin.name) ?? true) { continue }
        let final: URL
        switch pin.kind {
        case .tarball, .binary: final = toolsDirectory.appendingPathComponent(pin.name)
        case .plugin: final = plugins.appendingPathComponent(pin.name)
        }
        let marker = toolsDirectory.appendingPathComponent(".\(pin.name)-\(pin.version)")
        let present: Bool
        switch pin.kind {
        case .tarball, .binary: present = (names == nil || extra) && FileManager.default.isExecutableFile(atPath: final.path) && fm.fileExists(atPath: marker.path)
        case .plugin: present = toolFileOK(final, sha: pin.sha256)
        }
        if present { if !lazy { progress("\(pin.name) \(pin.version): present") }; continue }
        progress("\(pin.name) \(pin.version): downloading")
        let download = work.appendingPathComponent(pin.file)
        if pin.name == Tools.modelPlugin, mirror == nil {
            do { try downloadModelTool(pin: pin, to: download, work: work) }
            catch { bail("download failed for \(pin.name): \(error.localizedDescription)") }
        } else {
            let r: ToolDownloadProcess.Result
            do {
                r = try downloadTool(["--fail", lazy ? "--progress-bar" : "--silent", "--show-error", "--location",
                                     "--connect-timeout", "15", "--max-time", "180", "--retry", "3", "--output", download.path, pin.url(mirror: mirror)])
            } catch { bail("download failed for \(pin.name): \(error.localizedDescription)") }
            if let signal = r.cancelledSignal {
                try? fm.removeItem(at: work)
                exit(128 + signal)
            }
            guard r.code == 0 else { bail("download failed for \(pin.name): curl exited \(r.code)") }
        }
        guard (try? Digest.sha256(file: download)) == "sha256:" + pin.sha256 else {
            bail("SHA-256 mismatch for \(pin.file); discarded. Nothing from this download was installed. Earlier setup changes remain.")
        }
        var staged = download
        if case .tarball(let member) = pin.kind {
            let x = run("/usr/bin/tar", ["-xzf", download.path, "-C", work.path, member])
            guard x.code == 0 else { bail("cannot unpack \(pin.file): \(x.out)") }
            staged = work.appendingPathComponent(member)
        }
        ready.append((pin, staged, final, marker))
    }
    for item in ready {
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.staged.path)
            // One atomic replacement: cancellation can retain only a complete, verified executable.
            guard rename(item.staged.path, item.final.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for old in (try? fm.contentsOfDirectory(atPath: toolsDirectory.path)) ?? [] where old.hasPrefix(".\(item.pin.name)-") {
                try? fm.removeItem(at: toolsDirectory.appendingPathComponent(old))
            }
            _ = fm.createFile(atPath: item.marker.path, contents: nil)
        } catch { bail("cannot install \(item.pin.name): \(error.localizedDescription)") }
    }
    if link { linkPlugins(only: names) }
    if link { for item in ready where Tools.extras.contains(item.pin) { linkExtra(item.pin.name) } }
    if let lazyLink, let name = names?.first, !LazyToolPlugin.retainsStub(name),
       LazyToolPlugin.ownsStub(lazyLink, name: name, paths: paths, receipt: setupReceipt()) {
        let target = plugins.appendingPathComponent(name)
        do {
            try LazyToolPlugin.replaceOwned(lazyLink, with: target, receipt: setupReceipt(), record: setupRecord)
        } catch { bail("cannot replace \(name) stub: \(error.localizedDescription)") }
    }
    let adapter = BuildKitAdapter(paths: paths)
    if !lazy && (names?.contains(BuildKitAdapter.toolName) ?? (names == nil && adapter.configured)) {
        do {
            _ = try adapter.install(progress: { note($0.trimmingCharacters(in: .newlines)) })
            note("\(BuildKitAdapter.toolName): installed")
        } catch { bail(error.localizedDescription) }
    }
    if !lazy && names == nil { note("tools in \(toolsDirectory.path)") }
    // CLOEXEC releases the lock only once the upstream executable has been opened successfully.
    handoff?()
}

/// Managed copies in <NOODLE_HOME>/tools that no longer match this build's pins. Tools the user
/// installed elsewhere are never listed; absent tools are not listed either (nothing to refresh).
func staleManagedTools() -> Set<String> {
    let fm = FileManager.default
    var stale = Set<String>()
    for pin in Tools.pins {
        switch pin.kind {
        case .binary: break // optional extras are not refreshed
        case .tarball:
            let marker = toolsDirectory.appendingPathComponent(".\(pin.name)-\(pin.version)")
            if fm.isExecutableFile(atPath: Tools.docker(paths).path), !fm.fileExists(atPath: marker.path) { stale.insert(pin.name) }
        case .plugin:
            let file = Tools.pluginDirectory(paths).appendingPathComponent(pin.name)
            if fm.fileExists(atPath: file.path), !toolFileOK(file, sha: pin.sha256) { stale.insert(pin.name) }
        }
    }
    return stale
}

/// After an app update: re-fetch only Noodle's own out-of-date copies, with the usual SHA-256 check.
func toolsRefreshStale() {
    let receipt = setupReceipt()
    let hasStubs = receipt.keys.contains { key in
        guard key.hasPrefix("link:") else { return false }
        let link = URL(fileURLWithPath: String(key.dropFirst(5)))
        return LazyToolPlugin.ownsStub(link, name: link.lastPathComponent, paths: paths, receipt: receipt)
    }
    if hasStubs {
        do {
            let cli = try setupTerminal(docker: nil, addPath: false)
            try installPluginStubs(cli: cli, only: [])
        } catch { die("cannot refresh owned plugin stubs: \(error.localizedDescription)") }
    }
    let stale = staleManagedTools()
    guard !stale.isEmpty else { return }
    note("refreshing managed tools: \(stale.sorted().joined(separator: ", "))")
    toolsInstall(names: stale)
}

/// Link our plugins into <DOCKER_CONFIG>/cli-plugins, but only names that do not exist there yet.
func linkPlugins(only: Set<String>? = nil) {
    let fm = FileManager.default
    let dir = dockerConfigDirectory.appendingPathComponent("cli-plugins", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let existing = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    for name in existing where only?.contains(name) ?? true {
        if LazyToolPlugin.retainsStub(name) { continue }
        let link = dir.appendingPathComponent(name)
        let target = Tools.pluginDirectory(paths).appendingPathComponent(name)
        if LazyToolPlugin.ownsStub(link, name: name, paths: paths, receipt: setupReceipt()), fm.isExecutableFile(atPath: target.path) {
            do {
                try LazyToolPlugin.replaceOwned(link, with: target, receipt: setupReceipt(), record: setupRecord)
            } catch { err("warning: cannot replace \(name) stub: \(error.localizedDescription)") }
        }
    }
    for name in Tools.linksToCreate(existing: existing) where only?.contains(name) ?? true {
        guard FileManager.default.isExecutableFile(atPath: Tools.pluginDirectory(paths).appendingPathComponent(name).path) else { continue }
        do {
            let link = dir.appendingPathComponent(name)
            let target: String
            if LazyToolPlugin.retainsStub(name) {
                let cli = try setupTerminal(docker: nil, addPath: false)
                target = try writePluginStub(name, cli: cli).path
            } else { target = Tools.pluginDirectory(paths).appendingPathComponent(name).path }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            do { try setupRecordLink(link, target: target) }
            catch { try? fm.removeItem(at: link); throw error }
            note("linked \(name) into \(dir.path)")
        } catch { err("warning: cannot link \(name): \(error.localizedDescription)") }
    }
    for name in Tools.pins.map(\.name) where existing.contains(name) && only == nil {
        note("kept existing \(name) in \(dir.path)")
    }
}

/// Remove only unchanged links that this installation recorded creating.
func unlinkPlugins() {
    let fm = FileManager.default
    let dir = dockerConfigDirectory.appendingPathComponent("cli-plugins", isDirectory: true)
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
        let link = dir.appendingPathComponent(name)
        if setupOwnedLink(link) {
            do { try fm.removeItem(at: link); out("unlinked \(name)") }
            catch { err("warning: cannot unlink \(name): \(error.localizedDescription)") }
        }
    }
}

/// Expose an optional tool as ~/.local/bin/<name>, only when that name is free there.
func linkExtra(_ name: String) {
    let link = setupBin.appendingPathComponent(name)
    let target = toolsDirectory.appendingPathComponent(name).path
    guard !((try? FileManager.default.contentsOfDirectory(atPath: setupBin.path)) ?? []).contains(name) else {
        if !setupOwnedLink(link) { note("kept existing \(link.path); Noodle's copy is \(target)") }
        return
    }
    do {
        try FileManager.default.createDirectory(at: setupBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        do { try setupRecordLink(link, target: target) }
        catch { try? FileManager.default.removeItem(at: link); throw error }
        note("linked \(name) into \(setupBin.path)")
    } catch { err("warning: cannot link \(name): \(error.localizedDescription)") }
}

func toolsStatus(json: Bool = false) {
    var rows: [(name: String, version: String, installed: Bool)] = []
    for pin in Tools.pins + Tools.extras {
        let path: URL
        switch pin.kind {
        case .tarball, .binary: path = toolsDirectory.appendingPathComponent(pin.name)
        case .plugin: path = Tools.pluginDirectory(paths).appendingPathComponent(pin.name)
        }
        let ok = FileManager.default.isExecutableFile(atPath: path.path)
            && { if case .plugin = pin.kind { return toolFileOK(path, sha: pin.sha256) } else { return true } }()
        if !ok && Tools.extras.contains(pin) { continue } // optional tools show only once installed
        rows.append((pin.name, pin.version, ok))
    }
    let adapter = BuildKitAdapter(paths: paths)
    if adapter.configured, let pin = try? adapter.pin() {
        let installed = (try? adapter.executable()) != nil
        rows.append((BuildKitAdapter.toolName, pin.version, installed))
    }
    if json { jsonOut(toolsStatusJSON(rows)); return }
    for r in rows { out("\(r.name) \(r.version): \(r.installed ? "installed" : "not installed")") }
}

func toolsRemove() {
    let installLock: ToolInstallLock
    do { installLock = try ToolInstallLock(paths: paths) }
    catch { die("cannot lock tools removal: \(error.localizedDescription)") }
    defer { withExtendedLifetime(installLock) {} }
    unlinkPlugins()
    for name in Tools.extras.map(\.name) {
        let link = setupBin.appendingPathComponent(name)
        if setupOwnedLink(link) { try? FileManager.default.removeItem(at: link); out("unlinked \(name)") }
    }
    if FileManager.default.fileExists(atPath: toolsDirectory.path) {
        do { try FileManager.default.removeItem(at: toolsDirectory) }
        catch { die("cannot remove tools: \(error.localizedDescription)") }
        out("Removed \(toolsDirectory.path)")
    } else { out("No tools installed") }
}
