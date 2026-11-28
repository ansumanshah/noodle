import Foundation

// MARK: list, status, delete

private func state(_ cfg: MachineConfig) -> String {
    helperPID(machineDir(cfg.name)) != nil ? "running" : (cfg.ready ? "stopped" : "incomplete")
}

func machineList(_ args: [String]) {
    guard args.allSatisfy({ $0 == "--json" }) else { usageDie("usage: noodle machine list [--json]") }
    let all = allMachines()
    if args.contains("--json") {
        struct Entry: Encodable {
            let name: String
            let state: String
            let distro: String
            let image: String
            let cpus: Int
            let memoryMiB: Int
            let diskGiB: Int
        }
        let entries = all.map { m in
            Entry(name: m.name, state: state(m), distro: m.distro, image: m.image,
                  cpus: m.cpus, memoryMiB: m.memoryMiB, diskGiB: m.diskGiB)
        }
        out(jsonLine(encoding: entries))
        return
    }
    if all.isEmpty { out("No machines. Create one with `noodle machine create NAME`."); return }
    out("NAME".padding(toLength: 16, withPad: " ", startingAt: 0) + "STATE".padding(toLength: 12, withPad: " ", startingAt: 0) + "DISTRIBUTION".padding(toLength: 9, withPad: " ", startingAt: 0) + "CPUS  MEMORY     DISK")
    for m in all {
        let disk = fmtBytes(allocated(machineDir(m.name).appendingPathComponent("disk.img")))
        out(m.name.padding(toLength: 16, withPad: " ", startingAt: 0) + state(m).padding(toLength: 12, withPad: " ", startingAt: 0) + m.distro.padding(toLength: 9, withPad: " ", startingAt: 0)
            + String(m.cpus).padding(toLength: 6, withPad: " ", startingAt: 0) + fmtBytes(UInt64(m.memoryMiB) << 20).padding(toLength: 11, withPad: " ", startingAt: 0) + disk)
    }
}

func machineStatus(name: String, json: Bool = false) {
    let (dir, cfg) = loadMachine(name)
    let pid = helperPID(dir)
    if json {
        var address: String?
        if pid != nil {
            var request = MachineRequest(); request.args = ["cat", "/run/noodle-ip"]
            let ip = Box()
            _ = runMachineSession(socket: sock(dir), request: request, forwardInput: false) { ip.append($0) }
            address = ip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        jsonOut(machineStatusJSON(MachineStatusFields(
            name: cfg.name, state: state(cfg), image: cfg.image, user: cfg.user, cpus: cfg.cpus, memoryMiB: cfg.memoryMiB,
            diskGiB: cfg.diskGiB, systemd: cfg.systemd == true, share: cfg.share, pid: pid, address: address)))
        return
    }
    out("name:     \(cfg.name)\nstate:    \(state(cfg))\nimage:    \(cfg.image)\nuser:     \(cfg.user) (uid \(cfg.uid))\nresources: \(cfg.cpus) CPUs, \(cfg.memoryMiB) MiB memory, \(cfg.diskGiB) GiB disk (\(fmtBytes(allocated(dir.appendingPathComponent("disk.img")))) used)")
    out("systemd:  \(cfg.systemd == true ? "enabled" : "disabled (minimal init)")")
    out("share:    \(cfg.share.map { "\($0) at /mnt/share" } ?? "none")")
    guard let pid else { return }
    out("VM process: pid \(pid), \(run("/bin/ps", ["-o", "rss=", "-p", String(pid)]).out.trimmingCharacters(in: .whitespaces)) KiB resident")
    var request = MachineRequest(); request.args = ["cat", "/run/noodle-ip"]
    let ip = Box()
    _ = runMachineSession(socket: sock(dir), request: request, forwardInput: false) { ip.append($0) }
    out("address:  \(ip.text.trimmingCharacters(in: .whitespacesAndNewlines))")
}

private final class Box: @unchecked Sendable {
    var bytes: [UInt8] = []
    let lock = NSLock()
    func append(_ b: [UInt8]) { lock.lock(); bytes += b; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}
