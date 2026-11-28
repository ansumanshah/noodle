import Foundation

func cmdPod(_ args: [String]) {
    guard let command = args.first, !["help", "--help", "-h"].contains(command) else { out(podUsage); return }
    if args.dropFirst().elementsEqual(["--help"]) { out(podUsage); return }
    let endpoint = podEndpoint()
    do {
        let remaining = Array(args.dropFirst())
        if command == "create" { try podCreate(remaining, endpoint); return }
        let json = remaining.contains("--json")
        if command == "ps" {
            guard remaining.allSatisfy({ $0 == "--json" }) else { throw CLIError.usage(podUsage) }
            let pods = try podList(endpoint)
            if json { try podPrintJSON(pods.map(\.summary)) } else { podPrintTable(pods) }
            return
        }
        guard ["inspect", "start", "stop", "restart", "rm", "logs", "top"].contains(command) else { throw CLIError.usage(podUsage) }
        let force = remaining.contains("-f") || remaining.contains("--force")
        let flags: Set<String> = command == "rm" ? ["--json", "-f", "--force"] : ["--json"]
        let positionals = remaining.filter { !flags.contains($0) }
        guard positionals.count == 1, let reference = positionals.first, !reference.isEmpty, !reference.hasPrefix("-") else { throw CLIError.usage(podUsage) }
        let pod = try podFind(reference, endpoint)
        switch command {
        case "inspect":
            if json { try podPrintJSON(podInspect(pod, endpoint)) }
            else {
                podPrintTable([pod])
                out("SHARE\tnet")
                out("CONTAINER ID\tNAME\tROLE\tSTATE")
                for container in pod.containers {
                    out("\(container.id.prefix(12))\t\(container.name)\t\(container.id == pod.infra.id ? "network" : "member")\t\(container.state)")
                }
            }
            return
        case "logs": try podLogs(pod, endpoint, json: json); return
        case "top": try podTop(pod, endpoint, json: json); return
        case "start": try podStart(pod, endpoint)
        case "stop": try podStop(pod, endpoint)
        case "restart":
            try podRequireRestartable(pod.members, endpoint)
            try podStop(pod, endpoint)
            try podStart(podFind(pod.infra.id, endpoint), endpoint)
        case "rm":
            guard force || !pod.containers.contains(where: \.running) else { throw CLIError("pod is running; stop it first or use pod rm -f") }
            for container in Array(pod.members.reversed()) + [pod.infra] {
                try endpoint.call("DELETE", podRoute(container) + (force ? "?force=1" : ""), ok: [404])
            }
            if json { try podPrintJSON(["id": pod.infra.id, "name": pod.name, "removed": pod.containers.map(\.id)]) }
            else { out("POD ID\tNAME\tREMOVED"); out("\(pod.infra.id.prefix(12))\t\(pod.name)\t\(pod.containers.count)") }
            return
        default: break
        }
        let refreshed = try podFind(pod.infra.id, endpoint)
        if json { try podPrintJSON(refreshed.summary) } else { podPrintTable([refreshed]) }
    } catch { die(error) }
}
