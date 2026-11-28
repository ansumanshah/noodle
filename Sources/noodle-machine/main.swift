import Foundation

// noodle-machine: hosts one Linux machine VM. Started by `noodle machine start`, one process per running
// machine, gone when the machine stops. Not linked into noodled.
//   noodle-machine run --dir D --kernel K --initramfs I --cpus N --memory MIB --user U --uid N --host H [--share PATH] [--seed] [--systemd]
// Clients (the CLI) connect to D/s, a unix socket; every connection is bridged byte for byte to the guest agent.

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data(("noodle-machine: " + s + "\n").utf8))
    exit(1)
}

if CommandLine.arguments.dropFirst().first == "raw-run" {
    rawRun(Array(CommandLine.arguments.dropFirst(2)))
}

var opts: [String: String] = [:]
var flags = Set<String>()
var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "run" else { fail("usage: noodle-machine run --dir D ...") }
args.removeFirst()
while let a = args.first {
    args.removeFirst()
    if a == "--seed" || a == "--systemd" { flags.insert(String(a.dropFirst(2))); continue }
    guard a.hasPrefix("--"), let v = args.first else { fail("bad argument \(a)") }
    args.removeFirst()
    opts[String(a.dropFirst(2))] = v
}
let given = opts
func opt(_ k: String) -> String {
    guard let v = given[k] else { fail("missing --\(k)") }
    return v
}

let dir = URL(fileURLWithPath: opt("dir"), isDirectory: true)
let spec = MachineSpec(
    directory: dir, kernel: URL(fileURLWithPath: opt("kernel")), initramfs: URL(fileURLWithPath: opt("initramfs")),
    cpus: Int(opt("cpus")) ?? 2, memoryMiB: Int(opt("memory")) ?? 2048, user: opt("user"), uid: UInt32(opt("uid")) ?? 1000,
    host: opt("host"), share: opts["share"].map { URL(fileURLWithPath: $0, isDirectory: true) }, seed: flags.contains("seed"), systemd: flags.contains("systemd"))

// The lock marks "running": held for the life of this process, released by the kernel if it dies.
let lockFD = open(dir.appendingPathComponent("lock").path, O_RDWR | O_CREAT, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("machine is already running") }
_ = ftruncate(lockFD, 0)
_ = "\(getpid())\n".withCString { write(lockFD, $0, strlen($0)) }   // `noodle machine stop` reads the pid from here
Host.socketPath = dir.appendingPathComponent("s").path
unlink(Host.socketPath)

let machine = MachineVM(spec: spec) { error in
    if let error { FileHandle.standardError.write(Data("noodle-machine: VM stopped: \(error)\n".utf8)) }
    Host.finish(error == nil ? 0 : 1)
}

// A client hanging up mid-output must fail that write with EPIPE (bridge ends the connection), not kill the VM.
signal(SIGPIPE, SIG_IGN)
Task {
    do { try await machine.start() } catch { unlink(Host.socketPath); fail("\(error)") }
    serve(machine: machine, path: Host.socketPath)
}

// SIGTERM from `noodle machine stop` after a graceful poweroff timed out: hard stop.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { machine.forceStop { Host.finish(0) } }
term.resume()
dispatchMain()
