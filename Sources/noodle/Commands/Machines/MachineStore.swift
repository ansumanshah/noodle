import Foundation

infix operator ?! : NilCoalescingPrecedence
func ?! <T>(value: T?, fail: @autoclosure () -> Never) -> T {
    if let value { return value }
    fail()
}

let machinesRoot = paths.root.appendingPathComponent("machines", isDirectory: true)

/// Official images, pinned by index digest. `docker pull` verifies the content against it.
let distroImages = [
    "ubuntu": "ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852",
    "alpine": "alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f",
]

struct MachineConfig: Codable {
    var name: String
    var distro: String
    var image: String
    var cpus: Int
    var memoryMiB: Int
    var diskGiB: Int
    var user: String
    var uid: UInt32
    var share: String?
    var systemd: Bool? = nil // absent in machines created before systemd support
    var ready: Bool   // false until the rootfs is extracted and sudo is installed
}

func machineDir(_ name: String) -> URL { machinesRoot.appendingPathComponent(name, isDirectory: true) }
func sock(_ dir: URL) -> String { dir.appendingPathComponent("s").path }

func validName(_ n: String) -> Bool {
    n.range(of: "^[a-z0-9][a-z0-9-]{0,30}$", options: .regularExpression) != nil
}

func loadMachine(_ name: String) -> (dir: URL, cfg: MachineConfig) {
    let dir = machineDir(name)
    guard validName(name), let data = try? Data(contentsOf: dir.appendingPathComponent("machine.json")),
          let cfg = try? JSONDecoder().decode(MachineConfig.self, from: data) else { die("no machine named \(name). See `noodle machine list`.") }
    return (dir, cfg)
}

func allMachines() -> [MachineConfig] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: machinesRoot.path)) ?? []
    return names.sorted().compactMap { n in
        (try? Data(contentsOf: machineDir(n).appendingPathComponent("machine.json"))).flatMap { try? JSONDecoder().decode(MachineConfig.self, from: $0) }
    }
}

/// The helper holds an exclusive lock on `lock` for as long as it runs; its pid is the file's content.
func helperPID(_ dir: URL) -> Int32? {
    let fd = open(dir.appendingPathComponent("lock").path, O_RDWR)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
    var buf = [UInt8](repeating: 0, count: 32)
    let n = pread(fd, &buf, buf.count, 0)
    return n > 0 ? Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1 : -1
}

func parseMemory(_ s: String) -> Int? {
    let t = s.lowercased()
    for (suffix, mult) in [("gib", 1024), ("g", 1024), ("mib", 1), ("m", 1)] where t.hasSuffix(suffix) {
        return Int(t.dropLast(suffix.count)).map { $0 * mult }
    }
    return Int(t)
}

func fmtBytes(_ b: UInt64) -> String {
    b >= 1 << 30 ? String(format: "%.1f GiB", Double(b) / Double(1 << 30)) : String(format: "%.0f MiB", Double(b) / Double(1 << 20))
}

func allocated(_ url: URL) -> UInt64 {
    var st = stat()
    return stat(url.path, &st) == 0 ? UInt64(st.st_blocks) * 512 : 0
}
func writeConfig(_ cfg: MachineConfig, _ dir: URL) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try enc.encode(cfg).write(to: dir.appendingPathComponent("machine.json")) } catch { die("cannot write machine.json: \(error)") }
}
