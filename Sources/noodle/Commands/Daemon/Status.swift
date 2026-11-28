import Foundation
import NoodleCore

func cmdSetup(_ args: [String]) { setupInstall(args) }

func cmdUninstall(_ args: [String]) { setupUninstall(args) }

func cmdStatus() {
    let up = ping()
    out("engine:   \(up ? "running" : "stopped")")
    out("socket:   \(socketPath)")
    out("startup:  \(FileManager.default.fileExists(atPath: plistURL.path) ? "installed" : "not installed (run `noodle setup`)")")
    if let docker = which("docker") {
        let c = run(docker, ["context", "show"], extraEnv: dockerEnv)
        out("context:  \(c.code == 0 ? c.out : "unknown")")
        // The repair needs the Docker CLI, so the hint only appears when there is one.
        if !setupContextFileExists() { out("          no `noodle` Docker context (run `noodle doctor --fix`)") }
    }
    guard up else { exit(3) }
    if let info = httpGet("/info"), info.status == 200,
       let o = try? JSONSerialization.jsonObject(with: info.body) as? [String: Any] {
        let ver = o["ServerVersion"] as? String ?? "?"
        let running = o["ContainersRunning"] as? Int ?? 0, total = o["Containers"] as? Int ?? 0
        let cpus = o["NCPU"] as? Int ?? 0, mem = (o["MemTotal"] as? Int ?? 0) / 1_048_576
        out("version:  \(ver), \(running) running of \(total) containers")
        out("vm:       \(cpus) CPU, \(mem) MiB")
    }
}

func cmdStatusJSON() {
    let up = ping()
    let docker = which("docker")
    let daemon = noodledPath()
    let snapshot: [String: Any] = [
        "schemaVersion": 1,
        "daemon": ["reachable": up],
        "paths": ["data": paths.root.path, "socket": socketPath, "launchAgent": plistURL.path],
        "launchAgent": ["installed": FileManager.default.fileExists(atPath: plistURL.path)],
        "tools": [
            "docker": ["available": docker != nil, "path": docker as Any? ?? NSNull()],
            "noodled": ["available": FileManager.default.isExecutableFile(atPath: daemon), "path": daemon],
        ],
    ]
    out(jsonLine(snapshot))
    if !up { exit(3) }
}

func cmdStartupStatus(json: Bool = false) {
    guard let reply = httpGet("/noodle/vm/status"), reply.status == 200 else {
        guard ping() else { note("Docker API: unreachable"); exit(3) }
        note("Docker API: ready; VM readiness unavailable")
        exit(1)
    }
    guard let status = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
          let running = status["vmRunning"] as? Bool,
          let agentReady = status["guestAgentReady"] as? Bool else {
        die("Docker API is reachable but VM readiness returned an invalid response")
    }
    if json { jsonOut(startupStatusJSON(vmRunning: running, guestAgentReady: agentReady)); return }
    out("Docker API: ready")
    out("VM: \(running ? "running" : "not running")")
    out("Linux connection: \(agentReady ? "ready" : "not ready")")
}
