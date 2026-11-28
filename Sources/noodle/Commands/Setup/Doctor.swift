import Foundation
import NoodleCore
import Darwin

// Distribution diagnostics: inspect host integration without starting the daemon or VM.
func cmdDoctor(_ args: [String]) {
    guard args.allSatisfy({ $0 == "--fix" || $0 == "--json" }) else { usageDie("usage: noodle doctor [--fix] [--json]") }
    let fix = args.contains("--fix"), json = args.contains("--json")
    var records: [(message: String, fixed: Bool)] = []
    func say(_ s: String) { if json { err(s) } else { out(s) } }
    let fm = FileManager.default
    var issues = 0
    var unresolved = 0
    var repairable = 0
    func issue(_ message: String, repair: (() throws -> Void)? = nil) {
        issues += 1
        records.append((message, false))
        note("issue: \(message)")
        if !fix, repair != nil { repairable += 1 }
        guard fix, let repair else { unresolved += 1; return }
        do { try repair(); records[records.count - 1].fixed = true; say("fixed: \(message)") }
        catch { unresolved += 1; err("could not repair: \(error.localizedDescription)") }
    }
    let canLaunchctl = launchctlAllowed || env["NOODLE_LAUNCHCTL"] != nil
    let legacy = "dev.noodleapps.noodled"
    let legacyPlist = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(legacy).plist")
    if fm.fileExists(atPath: legacyPlist.path)
        || (canLaunchctl && setupLaunchctl(["print", "gui/\(uid)/\(legacy)"]).code == 0) {
        issue("legacy LaunchAgent \(legacy)") { try setupRemoveAgent(label: legacy) }
    }

    var staleAgent = false
    if fm.fileExists(atPath: plistURL.path) {
        let data = try? Data(contentsOf: plistURL)
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let program = (plist?["ProgramArguments"] as? [String])?.first ?? plist?["Program"] as? String
        staleAgent = program == nil || program != setupDaemonPath() || !fm.isExecutableFile(atPath: program ?? "")
    }
    if canLaunchctl {
        let loaded = setupLaunchctl(["print", launchdTarget])
        if loaded.code == 0,
           let line = loaded.out.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("program = ") }) {
            let program = String(line.trimmingCharacters(in: .whitespaces).dropFirst("program = ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            staleAgent = staleAgent || program != setupDaemonPath() || !fm.isExecutableFile(atPath: program)
        }
    }
    if staleAgent {
        issue("LaunchAgent points to a moved or missing Noodle engine") {
            guard fm.isExecutableFile(atPath: setupDaemonPath()) else {
                throw DoctorFailure("reinstall Noodle before repairing its LaunchAgent")
            }
            let daemon = setupDaemonPath()
            try setupRemoveAgent(label: agentLabel)
            try setupWriteAgent(daemon: daemon)
            say("LaunchAgent rewritten; run `noodle start` when ready")
        }
    }

    if let context = setupContext() {
        let endpoint = ((context["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
        if !setupOwnsContext(context) {
            issue("Docker context noodle belongs to another installation; left unchanged")
        } else if endpoint != "unix://\(socketPath)" {
            issue("Noodle Docker context has a stale socket endpoint") { try setupRepairContext() }
        }
    } else if setupContextFileExists() {
        issue("Docker context noodle metadata is unreadable; preserved")
    } else {
        issue("Noodle Docker context is missing, so `docker --context noodle` fails") { try setupRepairContext() }
    }

    let pluginDir = dockerConfigDirectory.appendingPathComponent("cli-plugins", isDirectory: true)
    for name in (try? fm.contentsOfDirectory(atPath: pluginDir.path)) ?? [] {
        let link = pluginDir.appendingPathComponent(name)
        guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else { continue }
        guard !fm.fileExists(atPath: link.path) else { continue }
        if setupOwnedLink(link) {
            issue("dangling Noodle plugin link \(name)") { try fm.removeItem(at: link) }
        } else {
            issue("dangling foreign plugin link \(name); preserved")
        }
    }

    if doctorDeadSocket() {
        issue("dead Noodle engine socket \(socketPath)") {
            // Recheck immediately before unlinking; a concurrently started daemon wins.
            if doctorDeadSocket() { try fm.removeItem(atPath: socketPath) }
        }
    }
    if let response = httpGet("/version"), response.status == 200,
       let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
       let daemonVersion = object["Version"] as? String, daemonVersion != version {
        issue("engine version \(daemonVersion) differs from CLI \(version); restart required") {
            let daemon = setupDaemonPath()
            guard fm.isExecutableFile(atPath: daemon) else { throw DoctorFailure("reinstall Noodle before repairing its LaunchAgent") }
            try setupRemoveAgent(label: agentLabel)
            try setupWriteAgent(daemon: daemon)
            guard waitFor({ !ping() }, seconds: 3) else {
                throw DoctorFailure("Noodle engine is running outside the Noodle LaunchAgent; stop it before restarting")
            }
            if doctorDeadSocket() { try fm.removeItem(atPath: socketPath) }
            say("Old Noodle engine stopped; run `noodle start` when ready")
        }
    }
    if issues == 0 { say("Noodle host integration is healthy") }
    else { say("\(issues) issue(s), \(unresolved) unresolved") }
    if repairable > 0 { say("Run `noodle doctor --fix` to repair what it can.") }
    if json { jsonOut(doctorJSON(issues: records, unresolved: unresolved, repairable: repairable)) }
    if unresolved > 0 { exit(1) }
}

private struct DoctorFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func doctorDeadSocket() -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath),
          attributes[.type] as? FileAttributeType == .typeSocket else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return DockerHTTP.connect(fd, path: socketPath) == false && errno == ECONNREFUSED
}
