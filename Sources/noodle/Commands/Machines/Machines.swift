import Foundation

// noodle machine: persistent Linux machines, one VM each.
// Nothing here runs, downloads or holds a process until `machine create`.

// MARK: dispatch

/// start, stop and restart take exactly one NAME. `status` parses its own arguments because it takes `--json`.
func machineNameUsageError(_ args: [String]) -> String? {
    guard let action = args.first, ["start", "stop", "restart"].contains(action) else { return nil }
    return args.count == 2 && !args[1].hasPrefix("-") ? nil : "usage: noodle machine \(action) NAME"
}

func cmdMachine(_ args: [String]) {
    let rest = Array(args.dropFirst())
    if let message = machineNameUsageError(args) { die(message, code: 2) }
    switch args.first {
    case "create": machineCreate(rest)
    case "list": machineList(rest)
    case "start": machineStart(name: rest.first ?! usageDie("usage: noodle machine start NAME"))
    case "stop": machineStop(name: rest.first ?! usageDie("usage: noodle machine stop NAME"))
    case "restart":
        let name = rest.first ?! usageDie("usage: noodle machine restart NAME")
        machineStop(name: name); machineStart(name: name)
    case "shell": machineShell(rest)
    case "delete": machineDelete(rest)
    case "status":
        let names = rest.filter { $0 != "--json" }
        guard names.count == 1, !names[0].hasPrefix("-"), rest.count - names.count <= 1 else { usageDie("usage: noodle machine status NAME [--json]") }
        machineStatus(name: names[0], json: rest.contains("--json"))
    default:
        guard args.isEmpty || args == ["help"] || args == ["--help"] || args == ["-h"] else {
            die("unknown machine command '\(args[0])'. Use noodle machine --help.", code: 2)
        }
        out(CommandTable.groupHelp("machine"))
    }
}
