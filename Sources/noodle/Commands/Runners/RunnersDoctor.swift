import Darwin
import Foundation
import NoodleCore

/// `noodle runners doctor [--json]`: reads this Mac's state and prints one line per check. Changes nothing.
func runnersDoctor(json: Bool) {
    let findings = RunnerDoctor.findings(doctorProbes())
    if json {
        jsonOut(encodableJSON(findings, key: "findings"))
    } else {
        for f in findings {
            out("\(f.level.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f.message)" + (f.fix.map { " Fix: \($0)" } ?? ""))
        }
        let problems = findings.filter { $0.level == .problem }.count, warnings = findings.filter { $0.level == .warning }.count
        out(problems == 0 ? (warnings == 0 ? "Ready to run jobs." : "Ready to run jobs, with \(warnings) warning(s).") : "\(problems) problem(s) to fix before jobs run reliably.")
    }
    exit(RunnerDoctor.exitCode(findings))
}

private func doctorProbes() -> RunnerDoctorProbes {
    var p = RunnerDoctorProbes()
    do { p.repos = try runnerStore.loadRepos() } catch { p.reposError = error.localizedDescription }
    let token = GitHubToken.fill()
    p.tokenPresent = token != nil
    let api = GitHubRunnersAPI { token }
    if token != nil {
        for r in p.repos { p.access[r.repo] = (try? blocking { await api.runnerAccess(r.repo) }) ?? .network }
    }
    p.reachability = doctorReachability()
    p.freeDiskBytes = RunnerHealth.freeBytes(near: paths.root.path)
    p.helperRunning = runnerStore.helperActive()
    p.logDirectory = runnerStore.logDirectory
    if p.helperRunning {
        let state = runnerStore.state()
        p.startFailures = RunnerStartFailure.active(state.startFailures)
        p.hold = state.hold
    }
    p.memoryCritical = SystemRunnerHealth().pressure() == .critical
    p.agent = doctorAgent()
    p.runnerInstall = doctorInstall()
    p.engineAnswers = ping()
    if let custom = doctorCommand("/usr/bin/pmset", ["-g", "custom"]), custom.code == 0 { p.sleep = RunnerSleepSettings(pmsetCustom: custom.out) }
    if p.repos.contains(where: { $0.macos }) {
        p.xcode = doctorXcode()
        // `defaults read` exits 1 when the key is not set: automatic login is off. A timeout or other failure stays unknown.
        if let r = doctorCommand("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"]) {
            p.autoLogin = r.code == 0 ? !r.out.isEmpty : r.code == 1 ? false : nil
        }
    }
    return p
}

private func doctorCommand(_ exe: String, _ args: [String]) -> (code: Int32, out: String)? {
    FileManager.default.isExecutableFile(atPath: exe) ? runWithTimeout(exe, args, timeout: 15) : nil
}

private func doctorReachability() -> RunnerReachability {
    // Any HTTP answer, even a 401, proves HTTPS works; no token is sent. A proxy may answer without local DNS.
    let api = GitHubRunnersAPI { nil }
    if (try? blocking({ () async -> Bool in
        (try? await URLSession.shared.data(for: api.request("/rate_limit"))) != nil
    })) == true { return .ok }
    // Only to explain the failure.
    var hints = addrinfo(), result: UnsafeMutablePointer<addrinfo>?
    hints.ai_socktype = SOCK_STREAM
    guard getaddrinfo("api.github.com", "443", &hints, &result) == 0 else { return .noDNS }
    freeaddrinfo(result)
    return .noHTTPS
}

private func doctorAgent() -> RunnerAgentState {
    guard let data = try? Data(contentsOf: runnersAgentPlist),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return .missing }
    // As `noodle doctor` checks the engine's agent: the program must exist and run, and the item must start at login.
    let program = (plist["ProgramArguments"] as? [String])?.first ?? plist["Program"] as? String
    guard let program, FileManager.default.isExecutableFile(atPath: program) else { return .badProgram }
    guard plist["RunAtLoad"] as? Bool == true else { return .noRunAtLoad }
    guard (plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false else { return .noRestart }
    if launchctlAllowed, run("/bin/launchctl", ["print", "gui/\(uid)/\(runnersAgentLabel)"]).code != 0 { return .notLoaded }
    return .ok
}

/// The runner archive is deleted after unpacking, so an install means it passed its checksum. Otherwise see if the host answers.
private func doctorInstall() -> RunnerInstallState {
    let install = runnerStore.directory.appendingPathComponent("macos-runner-\(RunnerPin.version)/run.sh")
    if FileManager.default.isExecutableFile(atPath: install.path) { return .installed }
    let r = runWithTimeout("/usr/bin/curl", ["--range", "0-0", "--silent", "--location", "--fail", "--connect-timeout", "10", "--max-time", "20",
                                     "--output", "/dev/null", RunnerPin.url], timeout: 30)
    return r.code == 0 ? .absentReachable : .absentUnreachable
}

private func doctorXcode() -> RunnerXcodeState {
    let path = doctorCommand("/usr/bin/xcode-select", ["-p"]).flatMap { $0.code == 0 && !$0.out.isEmpty ? $0.out : nil }
    // Only the Command Line Tools, or nothing: xcodebuild would just fail or open the install dialog.
    guard let path, path.contains(".app/"), FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") else {
        return RunnerXcodeState(selectedPath: path, licenseAccepted: false, firstLaunchDone: false)
    }
    guard FileManager.default.fileExists(atPath: path) else {
        return RunnerXcodeState(selectedPath: path, licenseAccepted: false, firstLaunchDone: false, selectedPathExists: false)
    }
    let license = runWithTimeout("/usr/bin/xcodebuild", ["-license", "check"], timeout: 30).code == 0
    let firstLaunch = runWithTimeout("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"], timeout: 30).code == 0
    return RunnerXcodeState(selectedPath: path, licenseAccepted: license, firstLaunchDone: firstLaunch)
}
