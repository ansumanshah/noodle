import Foundation
import NoodleCore

func ping() -> Bool { httpGet("/_ping")?.status == 200 }

func waitFor(_ cond: () -> Bool, seconds: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return cond()
}

// MARK: launchd

let uid = getuid()
let launchdTarget = "gui/\(uid)/\(agentLabel)"
func launchdLoaded() -> Bool { launchctlAllowed && run("/bin/launchctl", ["print", launchdTarget]).code == 0 }
func cmdStart() {
    if ping() { out("Already running"); return }
    if FileManager.default.fileExists(atPath: plistURL.path), launchctlAllowed {
        if !launchdLoaded() {
            let r = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
            if r.code != 0 && !launchdLoaded() { err("warning: launchctl bootstrap failed: \(r.out)") }
        }
        let k = run("/bin/launchctl", ["kickstart", launchdTarget])
        if k.code != 0 { err("warning: launchctl kickstart failed: \(k.out)") }
    } else {
        let exe = noodledPath()
        guard FileManager.default.isExecutableFile(atPath: exe) else { die("Noodle engine executable not found at \(exe)") }
        do { try paths.ensureDirectories() } catch { die(error.localizedDescription) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.standardInput = FileHandle.nullDevice
        let log = paths.root.appendingPathComponent("noodled.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { die("cannot create \(log.path)") }
        p.standardOutput = try? FileHandle(forWritingTo: log)
        p.standardError = p.standardOutput
        do { try p.run() } catch { die("cannot launch the Noodle engine: \(error.localizedDescription)") }
        out("Started the Noodle engine directly (no LaunchAgent; run `noodle setup` to install one)")
    }
    if waitFor(ping, seconds: 20) { out("Running") } else { die("Noodle engine did not answer on \(socketPath) within 20s. See \(paths.root.path)/noodled.log") }
}

func daemonPIDs() -> [Int32] {
    guard let lsof = which("lsof"), FileManager.default.fileExists(atPath: socketPath) else { return [] }
    let r = run(lsof, ["-t", socketPath])
    return r.out.split(separator: "\n").compactMap { Int32($0) }.filter { pid in
        run("/bin/ps", ["-p", String(pid), "-o", "comm="]).out.hasSuffix("noodled")
    }
}

func cmdStop() {
    guard ping() || !daemonPIDs().isEmpty else { out("Already stopped"); return }
    if launchdLoaded() {
        let r = run("/bin/launchctl", ["kill", "SIGTERM", launchdTarget])
        if r.code != 0 { err("warning: launchctl kill failed: \(r.out)") }
    }
    if ping() {
        let pids = daemonPIDs()
        if pids.isEmpty { die("cannot find the Noodle engine process to stop") }
        for p in pids { kill(p, SIGTERM) }
    }
    if waitFor({ !ping() }, seconds: 20) { out("Stopped") } else { die("Noodle engine is still answering after 20s") }
}
