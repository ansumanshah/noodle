import Foundation

/// 300 seconds; NOODLE_POD_DEADLINE_SECONDS shortens it so tests need not wait (a positive number only).
private let podDeadlineSeconds: Double = env["NOODLE_POD_DEADLINE_SECONDS"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 300

func podValidateLabel(_ value: String) throws {
    let key = String(value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    guard !key.isEmpty, key != podLabel, !key.hasPrefix(podLabel + ".") else {
        throw CLIError.usage("labels under \(podLabel) are reserved for pod membership")
    }
}

func podCreate(_ args: [String], _ endpoint: EngineEndpoint) throws {
    var name: String?, share: String?, labels: [String] = [], publish: [String] = []
    var json = false, index = 0
    while index < args.count {
        let token = args[index]
        if token == "--json" { json = true; index += 1; continue }
        let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var flag = parts[0], value: String
        if ["-p", "-l"].contains(String(token.prefix(2))), token.count > 2 {
            flag = String(token.prefix(2)); value = String(token.dropFirst(2))
        } else {
            guard ["--name", "--share", "--publish", "-p", "--label", "-l"].contains(flag) else {
                throw CLIError.usage("unknown pod create option: \(token)\n" + podUsage)
            }
            if parts.count == 2 { value = parts[1] }
            else {
                index += 1
                guard index < args.count else { throw CLIError.usage("\(flag) requires a value") }
                value = args[index]
            }
        }
        guard !value.isEmpty, !value.hasPrefix("-") else { throw CLIError.usage("\(flag) requires a nonempty value") }
        switch flag {
        case "--name":
            guard name == nil else { throw CLIError.usage("specify --name once") }
            name = value
        case "--share":
            guard share == nil else { throw CLIError.usage("specify --share once") }
            share = value
        case "-p", "--publish": publish.append(value)
        default: try podValidateLabel(value); labels.append(value)
        }
        index += 1
    }
    let podName = name ?? "pod-" + String(UUID().uuidString.lowercased().prefix(8))
    let nameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    guard let first = podName.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
          podName.unicodeScalars.allSatisfy({ nameChars.contains($0) }) else {
        throw CLIError.usage("pod name must start with a letter or number and contain only letters, numbers, _, . or -")
    }
    guard share == nil || share == "net" else {
        throw CLIError.usage("only --share net is supported; this engine does not implement IPC, UTS or PID namespace joining")
    }
    guard !(try podList(endpoint)).contains(where: { $0.name == podName }) else { throw CLIError("pod already exists: \(podName)") }
    let infraName = "noodle-pod-\(podName)-infra"
    var command = ["create", "--name", infraName, "--init", "--label", "\(podLabel)=\(podName)",
                   "--label", "\(podRoleLabel)=infra", "--label", "\(podShareLabel)=net"]
    for label in labels { command += ["--label", label] }
    for port in publish { command += ["--publish", port] }
    // Reuse a small base image and its blocking sleep, rather than ship a new
    // guest binary. --init reaps children and forwards stop signals to sleep.
    command += ["--entrypoint", "/bin/sleep", podInfraImage, "infinity"]
    let result = dk(command, timeout: podDeadlineSeconds, errorOutput: .standardError)
    if result.code == 124 { throw CLIError("docker client was killed or exceeded its \(Int(podDeadlineSeconds)) second deadline") }
    guard result.code == 0 else { throw CLIError("could not create pod network container (docker exit \(result.code))") }
    let pod = try podFind(podName, endpoint)
    if json { try podPrintJSON(pod.summary) } else { podPrintTable([pod]) }
}
