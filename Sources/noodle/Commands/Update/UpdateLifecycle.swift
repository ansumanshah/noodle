import Foundation
import NoodleCore

// The engine around an app replacement: stop it first (and refuse to replace if it will not stop),
// restart it with the new binary only if it was running, and never leave the old tools in charge.

/// A failed query is unknown, including a failed ping. Never assume a failed request means zero.
func runningContainerCount() -> Int? {
    guard let reply = try? EngineEndpoint(name: "noodled", socketPath: socketPath).call("GET", "/containers/json"),
          let list = (try? JSONSerialization.jsonObject(with: reply.body)) as? [Any] else { return nil }
    return list.count
}

/// The next step stops the engine, which stops running containers: say so and ask first.
func confirmInstall(yes: Bool, rollback: Bool = false) {
    // A stopped engine has no containers to lose. A live engine that fails the query stays unknown.
    guard !yes, ping() || !daemonPIDs().isEmpty,
          let warning = UpdateInstallWarning.message(running: runningContainerCount(), rollback: rollback) else { return }
    let action = rollback ? "roll back" : "install"
    guard isatty(STDIN_FILENO) != 0 else { usageDie("\(warning) Pass --yes to \(action) anyway.") }
    FileHandle.standardError.write(Data("\(warning) Continue? [y/N] ".utf8))
    guard readLine()?.lowercased().hasPrefix("y") == true else { die("cancelled", code: 1) }
}

/// Stop the engine (dies if it will not stop), swap the app, then start the engine with the new binary.
func installWithEngine(target: URL) {
    do { try UpdateInstaller.preflightInstall(target: target, paths: paths) } catch { die(error.localizedDescription) }
    replaceWithEngine(target: target) {
        let state = try UpdateInstaller.install(target: target, paths: paths)
        out("installed \(state.version) over \(target.path); previous app kept until `noodle update confirm`")
    }
}

func rollbackWithEngine(yes: Bool) {
    let target: URL
    do { target = try UpdateInstaller.preflightRollback(paths: paths) } catch { die(error.localizedDescription) }
    confirmInstall(yes: yes, rollback: true)
    replaceWithEngine(target: target) {
        try UpdateInstaller.rollback(paths: paths)
        out("restored the previous version")
    }
}

/// Both operations stop before replacing and start through the resulting bundle only if needed.
private func replaceWithEngine(target: URL, replace: () throws -> Void) {
    let pids = daemonPIDs()
    let wasRunning = ping() || !pids.isEmpty
    if wasRunning {
        guard !pids.isEmpty else { die("cannot find the Noodle engine process to stop; nothing was updated") }
        for pid in pids {
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { die("cannot stop the Noodle engine; nothing was updated") }
        }
        // A closed socket alone is not proof that the old daemon finished shutting down.
        guard waitFor({ pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } && !ping() }, seconds: 20) else {
            die("the engine did not stop; nothing was updated")
        }
    }
    do { try replace() } catch {
        if wasRunning, let old = updateHelper(in: target) {
            let restart = run(old, ["start"])
            if restart.code != 0 { err("The engine could not restart: \(restart.out)") }
        }
        die(error.localizedDescription)
    }
    guard wasRunning else { return }
    guard let new = updateHelper(in: target) else {
        die("The app was replaced, but it has no noodle tool to start it. Run `noodle start`.", code: UpdateCommandOutcome.restartFailedExitCode)
    }
    let r = run(new, ["start"], capture: true)
    if r.code == 0 { out("engine restarted with the new version") }
    else { die("The app was replaced, but the engine did not restart: \(r.out). Run `noodle start`.", code: UpdateCommandOutcome.restartFailedExitCode) }
}

/// After confirming, refresh tools with the installed app's own helper, because this binary may be an
/// older retained copy (for example in ~/.local/bin) with older pins.
func confirmUpdate(target: URL) {
    guard let installed = updateHelper(in: target) else {
        if FileManager.default.fileExists(atPath: Tools.directory(paths).path) {
            die("cannot refresh tools because the installed app's Noodle CLI was not found")
        }
        UpdateInstaller.confirm(paths: paths)
        out("confirmed")
        return
    }
    let mine = URL(fileURLWithPath: selfDirectory()).appendingPathComponent("noodle").path
    if URL(fileURLWithPath: installed).resolvingSymlinksInPath().path != mine {
        let r = run(installed, ["update", "confirm", "--app", target.path])
        if !r.out.isEmpty { out(r.out) }
        if r.code != 0 { exit(r.code) }
        return
    }
    UpdateInstaller.confirm(paths: paths)
    out("confirmed")
    toolsRefreshStale()
}
