import Foundation

private let containerEditUsage = """
usage: noodle container edit NAME [--env K=V] [--unset-env K]
       [--publish [HOST_IP:]HOST_PORT:CONTAINER_PORT[/tcp|udp]]
       [--unpublish SPEC] [--restart] [--dry-run]
       noodle container ports NAME [--json]
Environment changes apply at the next start. Use --restart to apply them now.
"""

/// These two container commands belong to Noodle; all other container commands use Docker.
func cmdContainer(_ args: [String]) {
    var args = args
    if args.count == 3, args[0] == "ports", args[1] == "--json" { args.swapAt(1, 2) }
    guard let command = args.first, command == "edit" || command == "ports" else {
        die(containerEditUsage + "\nFor other container commands, use docker --context noodle container.", code: 2)
    }
    guard args.count >= 2, !args[1].hasPrefix("-") else { usageDie(containerEditUsage) }
    let name = args[1]
    let escaped = podEscape(name)
    let endpoint = EngineEndpoint(name: "noodled", socketPath: socketPath)
    do {
        if command == "ports" {
            guard args.count == 2 || (args.count == 3 && args[2] == "--json") else { usageDie(containerEditUsage) }
            let reply = try endpoint.call("GET", "/containers/\(escaped)/noodle/ports")
            if args.count == 3 {
                FileHandle.standardOutput.write(reply.body + Data([10]))
                return
            }
            guard let ports = try JSONSerialization.jsonObject(with: reply.body) as? [[String: Any]] else {
                die("unexpected ports reply from the Noodle engine")
            }
            if ports.isEmpty { out("No listening TCP or UDP ports."); return }
            for port in ports {
                guard let number = port["port"] as? Int, let proto = port["protocol"] as? String,
                      let address = port["address"] as? String else { die("unexpected port in reply from the Noodle engine") }
                let process = port["process"] as? String
                let bindings = port["published"] as? [[String: String]] ?? []
                let published = bindings.map { binding in
                    let host = binding["HostIp"] ?? ""
                    return "\(host.contains(":") ? "[\(host)]" : host):\(binding["HostPort"] ?? "")"
                }.joined(separator: ", ")
                out("\(address.contains(":") ? "[\(address)]" : address):\(number)/\(proto)\(process.map { "  " + $0 } ?? "")  \(published.isEmpty ? "unpublished" : "published at " + published)")
            }
            return
        }

        var values: [String: [String]] = ["env": [], "unsetEnv": [], "publish": [], "unpublish": []]
        let keys = ["--env": "env", "--unset-env": "unsetEnv", "--publish": "publish", "--unpublish": "unpublish"]
        var restart = false, dryRun = false, index = 2
        while index < args.count {
            let flag = args[index]
            if flag == "--restart" { restart = true }
            else if flag == "--dry-run" { dryRun = true }
            else if let key = keys[flag] {
                index += 1
                guard index < args.count, !args[index].isEmpty else { usageDie("\(flag) requires a value\n" + containerEditUsage) }
                values[key, default: []].append(args[index])
            } else { usageDie("unknown flag: \(flag)\n" + containerEditUsage) }
            index += 1
        }
        var body: [String: Any] = values
        body["restart"] = restart
        body["dryRun"] = dryRun
        let reply = try endpoint.call("POST", "/containers/\(escaped)/noodle/edit", json: body)
        guard let result = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let message = result["message"] as? String else { die("unexpected edit reply from the Noodle engine") }
        out(message)
    } catch { die(error) }
}
