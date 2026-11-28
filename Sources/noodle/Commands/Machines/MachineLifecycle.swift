import Foundation

// MARK: start, stop

private func tail(_ url: URL) -> String {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(8).joined(separator: "\n")
}

func machineStart(name: String) {
    let (dir, cfg) = loadMachine(name)
    if helperPID(dir) != nil { out("\(name) is already running"); return }
    let seed = dir.appendingPathComponent("seed.tar")
    let seeded = FileManager.default.fileExists(atPath: seed.path)
    if !cfg.ready && !seeded { die("machine \(name) was not set up completely. Delete it and create it again.") }
    let selfDir = selfDirectory()
    let helper = [selfDir + "/noodle-machine", URL(fileURLWithPath: selfDir).deletingLastPathComponent().appendingPathComponent("MacOS/noodle-machine").path]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?! die("noodle-machine not found next to noodle")
    // Resolve from the real executable too: the installed CLI may be a symlink
    // outside the app, while boot resources live beside Contents/Helpers.
    let bundledResources = URL(fileURLWithPath: selfDir).deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)
    func boot(_ file: String) -> String? {
        [paths.bootDir, paths.resourcesDirectory, bundledResources].compactMap { $0?.appendingPathComponent(file).path }.first { FileManager.default.fileExists(atPath: $0) }
    }
    guard let kernel = boot("vmlinux"), let initramfs = boot("machine-initramfs.cpio.gz") else { die("machine boot files are missing (vmlinux, machine-initramfs.cpio.gz). Run `just resources`.") }
    var argv = [helper, "run", "--dir", dir.path, "--kernel", kernel, "--initramfs", initramfs, "--cpus", String(cfg.cpus), "--memory", String(cfg.memoryMiB),
                "--user", cfg.user, "--uid", String(cfg.uid), "--host", cfg.name]
    if let share = cfg.share { argv += ["--share", share] }
    if !cfg.ready { argv.append("--seed") }
    if cfg.ready && cfg.systemd == true { argv.append("--systemd") }
    let log = dir.appendingPathComponent("helper.log")
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))   // survives this terminal and its Ctrl-C
    var pid: pid_t = 0
    let cargs = argv.map { strdup($0) } + [nil]
    let rc = posix_spawn(&pid, helper, &actions, &attr, cargs, environ)
    guard rc == 0 else { die("cannot start noodle-machine: \(String(cString: strerror(rc)))") }
    // The helper takes the lock a moment after it starts; only then can the guest be probed.
    var exited = false
    var status: Int32 = 0
    let ready = waitFor({
        if waitpid(pid, &status, WNOHANG) == pid { exited = true; return true }
        guard helperPID(dir) != nil else { return false }
        var probe = MachineRequest(); probe.args = ["true"]
        return runMachineSession(socket: sock(dir), request: probe, forwardInput: false) == 0
    }, seconds: 120)
    if exited || !ready || helperPID(dir) == nil {
        die("machine \(name) did not start. \(tail(log))\n\(tail(dir.appendingPathComponent("console.log")))")
    }
    out("Started \(name)")
}

func machineStop(name: String) {
    let (dir, cfg) = loadMachine(name)
    guard let pid = helperPID(dir) else { out("\(name) is already stopped"); return }
    var request = MachineRequest(); request.poweroff = true
    _ = runMachineSession(socket: sock(dir), request: request, forwardInput: false)
    if !waitFor({ helperPID(dir) == nil }, seconds: cfg.ready && cfg.systemd == true ? 90 : 15) {
        kill(pid, SIGTERM)   // the guest did not power off; the helper stops the VM hard
        if !waitFor({ helperPID(dir) == nil }, seconds: 10) { kill(pid, SIGKILL) }
        if cfg.ready && cfg.systemd == true { die("machine \(name) did not shut down cleanly; forced the VM to stop. See console.log and the VM process log (helper.log) in \(dir.path).") }
    }
    out("Stopped \(name)")
}
func machineDelete(_ args: [String]) {
    let names = args.filter { !yesFlags.contains($0) }
    guard names.count == 1, let name = names.first, !name.hasPrefix("-"),
          args.count == (hasYes(args) ? 2 : 1) else {
        die("usage: noodle machine delete NAME [--yes]", code: 2)
    }
    let (dir, _) = loadMachine(name)
    if !hasYes(args) {
        guard isatty(0) != 0 else { usageDie("deleting \(name) removes its disk and everything in its home. Pass --yes to confirm.") }
        FileHandle.standardError.write(Data("Delete machine \(name) and all its data? [y/N] ".utf8))
        guard readLine()?.lowercased().hasPrefix("y") == true else { die("not deleted", code: 1) }
    }
    if helperPID(dir) != nil { machineStop(name: name) }
    do { try FileManager.default.removeItem(at: dir) } catch { die("cannot remove \(dir.path): \(error)") }
    if ((try? FileManager.default.contentsOfDirectory(atPath: machinesRoot.path)) ?? []).isEmpty { try? FileManager.default.removeItem(at: machinesRoot) }
    out("Deleted \(name)")
}
