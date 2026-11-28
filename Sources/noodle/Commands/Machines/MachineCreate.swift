import Foundation

// MARK: create

func machineCreate(_ args: [String]) {
    var name: String?, distro = "ubuntu", image: String?, cpus = 2, memory = 2048, diskGiB = 20, share: String?
    var systemd = false
    var it = args.makeIterator()
    while let a = it.next() {
        func value() -> String { it.next() ?! usageDie("\(a) needs a value") }
        switch a {
        case "--systemd": systemd = true
        case "--distro": distro = value()
        case "--image": image = value()
        case "--cpus": cpus = Int(value()) ?! usageDie("--cpus needs a number")
        case "--memory": memory = parseMemory(value()) ?! usageDie("--memory needs a size such as 2G or 512M")
        case "--disk":
            let raw = value().lowercased()
            let number = raw.hasSuffix("gib") ? String(raw.dropLast(3)) : (raw.hasSuffix("g") ? String(raw.dropLast()) : raw)
            diskGiB = Int(number) ?! usageDie("--disk needs a whole number of GiB, such as 20 or 20G")
        case "--share": share = value()
        default: if a.hasPrefix("-") || name != nil { usageDie("unknown argument \(a)") }; name = a
        }
    }
    guard let name, validName(name) else { usageDie("usage: noodle machine create NAME (lowercase letters, digits, dashes)") }
    guard image != nil || distroImages[distro] != nil else { usageDie("unknown distro \(distro). Use ubuntu, alpine or --image REF.") }
    if systemd && image == nil && distro == "alpine" {
        usageDie("--systemd requires systemd and /sbin/init. Use --distro ubuntu, or --image REF with systemd, an executable /sbin/init pointing to systemd, and systemctl installed (Ubuntu, Debian or Fedora).")
    }
    guard cpus >= 1, memory >= 256 else { usageDie("a machine needs at least 1 CPU and 256 MiB") }
    guard (1...16384).contains(diskGiB) else { usageDie("--disk must be between 1 and 16384 GiB") }
    var sharePath: String?
    if let share {
        var isDir: ObjCBool = false
        let resolved = URL(fileURLWithPath: (share as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { die("--share \(share) is not a folder") }
        sharePath = resolved
    }
    let user = NSUserName()
    guard user.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil else { die("the Mac user name \(user) cannot be used as a Linux user name") }
    let dir = machineDir(name)
    if FileManager.default.fileExists(atPath: dir.path) { die("machine \(name) already exists") }
    guard sock(dir).utf8.count < 100 else { die("NOODLE_HOME is too deep for the machine socket path") }
    let ref = image ?? distroImages[distro]!
    var cfg = MachineConfig(name: name, distro: image == nil ? distro : "custom", image: ref, cpus: cpus, memoryMiB: memory, diskGiB: diskGiB,
                            user: user, uid: getuid(), share: sharePath, systemd: systemd, ready: false)
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { die("cannot create \(dir.path): \(error)") }
    func abort(_ message: String) -> Never {
        if helperPID(dir) != nil { machineStop(name: name) }
        try? FileManager.default.removeItem(at: dir)
        die(message)
    }

    // 1. root filesystem: the pinned image, exported through the engine, once
    if !ping() { cmdStart() }
    guard let dockerPath = which("docker") else { abort("docker CLI not found; run `noodle tools install`") }
    func docker(_ a: [String], stdout: FileHandle? = nil) -> Int32 {
        runWithTimeout(dockerPath, a, environment: engineDockerEnvironment, timeout: 600,
                       stdout: stdout ?? FileHandle.standardOutput, errorOutput: FileHandle.standardError).code
    }
    err("Pulling \(ref)")
    guard docker(["pull", "--platform", "linux/arm64", "-q", ref], stdout: FileHandle.standardError) == 0 else { abort("could not pull \(ref)") }
    let idFile = dir.appendingPathComponent("container-id")
    guard docker(["create", "--platform", "linux/arm64", "--cidfile", idFile.path, ref, "/bin/true"], stdout: FileHandle.standardError) == 0,
          let idText = try? String(contentsOf: idFile, encoding: .utf8) else { abort("could not create a container from \(ref)") }
    let id = idText.trimmingCharacters(in: .whitespacesAndNewlines)
    try? FileManager.default.removeItem(at: idFile)
    let seed = dir.appendingPathComponent("seed.tar")
    _ = FileManager.default.createFile(atPath: seed.path, contents: nil)
    let exported = docker(["export", id], stdout: try? FileHandle(forWritingTo: seed))
    _ = docker(["rm", "-f", id], stdout: FileHandle.nullDevice)
    guard exported == 0 else { abort("could not export \(ref)") }
    if let size = (try? FileManager.default.attributesOfItem(atPath: seed.path)[.size] as? UInt64), size % 512 != 0, let h = try? FileHandle(forWritingTo: seed) {
        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(count: Int(512 - size % 512))); try? h.close()
    }

    // 2. the machine's own disk: sparse, so it costs what is written
    guard let tools = paths.resourcesDirectory else { abort("Noodle resources not found") }
    let disk = dir.appendingPathComponent("disk.img")
    let fd = open(disk.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0, ftruncate(fd, off_t(cfg.diskGiB) << 30) == 0 else { abort("cannot create the disk image") }
    close(fd)
    let mke2fs = run(tools.appendingPathComponent("mke2fs").path, ["-F", "-q", "-t", "ext4", "-b", "4096", "-J", "size=64", "-E", "nodiscard,lazy_itable_init=1,lazy_journal_init=1", disk.path],
                     extraEnv: ["MKE2FS_CONFIG": tools.appendingPathComponent("mke2fs.conf").path])
    guard mke2fs.code == 0 else { abort("could not format the disk: \(mke2fs.out)") }
    writeConfig(cfg, dir)

    // 3. Bootstrap with minimal init. Validate custom images before installing any packages.
    machineStart(name: name)
    if systemd && image != nil {
        var check = MachineRequest(); check.args = ["/bin/sh", "-c", checkSystemdScript]
        guard runMachineSession(socket: sock(dir), request: check, forwardInput: false) == 0 else {
            abort("--systemd needs systemd, an executable /sbin/init pointing to systemd, and systemctl installed in the image. Use --distro ubuntu or a prepared Ubuntu, Debian or Fedora --image.")
        }
    }
    var request = MachineRequest(); request.args = ["/bin/sh", "-c", provisionScript]
    err("Installing sudo")
    guard runMachineSession(socket: sock(dir), request: request, forwardInput: false) == 0 else { abort("could not finish setting up the machine") }
    if systemd && image == nil {
        var setup = MachineRequest()
        setup.args = ["/bin/sh", "-c", installSystemdScript]
        err("Preparing systemd")
        guard runMachineSession(socket: sock(dir), request: setup, forwardInput: false) == 0 else {
            abort("--systemd needs systemd, an executable /sbin/init pointing to systemd, and systemctl installed in the image. Use --distro ubuntu or a prepared Ubuntu, Debian or Fedora --image.")
        }
    }
    cfg.ready = true
    writeConfig(cfg, dir)
    try? FileManager.default.removeItem(at: seed)
    if systemd { machineStop(name: name); machineStart(name: name) }
    out("Created machine \(name) (\(cfg.distro), \(cpus) CPUs, \(fmtBytes(UInt64(memory) << 20)) memory). Running. Try `noodle machine shell \(name)`.")
}

private let provisionScript = """
if command -v sudo >/dev/null 2>&1; then exit 0; fi
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q && apt-get install -y -q --no-install-recommends -o Dpkg::Options::=--force-unsafe-io sudo ca-certificates && rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then apk add -q --no-cache sudo
elif command -v dnf >/dev/null 2>&1; then dnf install -y -q sudo
elif command -v microdnf >/dev/null 2>&1; then microdnf install -y sudo
else echo "no supported package manager: install sudo yourself" >&2; exit 0; fi
"""

// Ubuntu's container image omits init. Custom images must already provide systemd.
private let checkSystemdScript = """
test -x /sbin/init && test -x /usr/bin/systemctl && command -v systemctl >/dev/null 2>&1 && case "$(readlink -f /sbin/init)" in */systemd) ;; *) false ;; esac
"""
private let installSystemdScript = """
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -y -q --no-install-recommends -o Dpkg::Options::=--force-unsafe-io systemd-sysv dbus && rm -rf /var/lib/apt/lists/* || exit 1
\(checkSystemdScript)
"""
