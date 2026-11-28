import Foundation

// MARK: shell

func machineShell(_ args: [String]) {
    var command: [String] = []
    var head = args
    if let dash = args.firstIndex(of: "--") {
        command = Array(args[(dash + 1)...])
        head = Array(args[..<dash])
    }
    guard head.count <= 1, !(head.first?.hasPrefix("-") ?? false) else { usageDie("usage: noodle machine shell [NAME] [-- CMD...]") }
    let name = head.first
    let all = allMachines()
    if name == nil && all.count != 1 { die(all.isEmpty ? "no machines. Create one with `noodle machine create NAME`." : "several machines exist; name one: \(all.map(\.name).joined(separator: ", "))") }
    let target = name ?? all[0].name
    let (dir, cfg) = loadMachine(target)
    if helperPID(dir) == nil { err("Starting \(target)"); machineStart(name: target) }
    var request = MachineRequest()
    request.tty = isatty(0) != 0 && isatty(1) != 0
    request.user = cfg.user
    request.args = command
    request.env = ["TERM=\(env["TERM"] ?? "xterm-256color")"] + (env["COLORTERM"].map { ["COLORTERM=\($0)"] } ?? [])
    if let share = cfg.share {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        if cwd == share || cwd.hasPrefix(share + "/") { request.cwd = "/mnt/share" + cwd.dropFirst(share.count) }
    }
    guard let code = runMachineSession(socket: sock(dir), request: request, forwardInput: true) else { die("lost the connection to \(target)", code: 255) }
    exit(code)
}
