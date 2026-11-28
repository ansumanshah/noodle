import Foundation
import NoodleCore

/// Emit the portable subset accepted by play. JSON quoting preserves shell arguments and env values.
func kubeGenerate(_ reference: String) throws {
    let engine = EngineEndpoint(name: "noodled", socketPath: socketPath)
    let all = try engine.containers()
    var members = all.filter { ($0["Labels"] as? [String: String])?[podLabel] == reference }
    let owners = Set(members.compactMap { ($0["Labels"] as? [String: String])?[kubeOwnerLabel] })
    guard owners.count <= 1 else { throw CLIError("pod name is ambiguous across namespaces; generate by container name") }
    var podName = reference
    var namespace = ""
    if members.isEmpty {
        let inspected = try engine.inspect("containers", reference)
        guard let id = inspected["Id"] as? String else { throw CLIError("container not found: \(reference)") }
        members = [["Id": id]]
        let labels = (inspected["Config"] as? [String: Any])?["Labels"] as? [String: String] ?? [:]
        podName = labels[podLabel] ?? String(kubeString(inspected["Name"]).drop(while: { $0 == "/" }))
        namespace = labels["dev.noodle.kube.namespace"] ?? ""
    }
    if let first = members.first, namespace.isEmpty { namespace = (first["Labels"] as? [String: String])?["dev.noodle.kube.namespace"] ?? "" }
    _ = try kubeName(podName, "generated metadata.name")
    var lines = ["apiVersion: v1", "kind: Pod", "metadata:", "  name: \(KubeYAML.quote(podName))", "spec:", "  restartPolicy: Never", "  containers:"]
    if !namespace.isEmpty { lines.insert("  namespace: \(KubeYAML.quote(namespace))", at: 4) }
    var ephemeralNames: [String: String] = [:]
    var volumes: [(name: String, source: [String])] = []
    var usedNames = Set<String>()
    for member in members.sorted(by: { kubeString($0["Id"]) < kubeString($1["Id"]) }) {
        let info = try engine.inspect("containers", kubeString(member["Id"]))
        let config = info["Config"] as? [String: Any] ?? [:]
        let host = info["HostConfig"] as? [String: Any] ?? [:]
        let labels = config["Labels"] as? [String: String] ?? [:]
        let rawName = String(kubeString(info["Name"]).drop(while: { $0 == "/" }))
        var name = labels["dev.noodle.kube.container"] ?? rawName
        // Pod lane infra containers carry the pod label too; preserving them as ordinary
        // containers avoids relying on private pod-lane labels or functions.
        if !usedNames.insert(name).inserted { name += "-\(usedNames.count)"; usedNames.insert(name) }
        _ = try kubeName(name, "generated container.name")
        lines += ["    - name: \(KubeYAML.quote(name))", "      image: \(KubeYAML.quote(kubeString(config["Image"])))"]
        for (docker, yaml) in [("Entrypoint", "command"), ("Cmd", "args")] {
            if let array = config[docker] as? [String] {
                lines.append("      \(yaml): [\(array.map { KubeYAML.quote($0) }.joined(separator: ", "))]")
            }
        }
        if let working = config["WorkingDir"] as? String, !working.isEmpty { lines.append("      workingDir: \(KubeYAML.quote(working))") }
        let environment = config["Env"] as? [String] ?? []
        if !environment.isEmpty {
            lines.append("      env:")
            for entry in environment {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                lines += ["        - name: \(KubeYAML.quote(String(entry[..<separator])))", "          value: \(KubeYAML.quote(String(entry[entry.index(after: separator)...])))"]
            }
        }
        let bindings = host["PortBindings"] as? [String: [[String: String]]] ?? [:]
        let exposed = config["ExposedPorts"] as? [String: Any] ?? [:]
        let portKeys = Set(bindings.keys).union(exposed.keys).sorted()
        if !portKeys.isEmpty {
            lines.append("      ports:")
            for key in portKeys {
                let parts = key.split(separator: "/")
                guard let number = parts.first, Int(number) != nil else { throw CLIError("cannot generate invalid port \(key)") }
                let proto = parts.count > 1 ? String(parts[1]).uppercased() : "TCP"
                let published = bindings[key] ?? []
                for binding in published.isEmpty ? [[:]] : published {
                    lines += ["        - containerPort: \(number)", "          protocol: \(proto)"]
                    if let hp = binding["HostPort"], !hp.isEmpty { lines.append("          hostPort: \(hp)") }
                    if let ip = binding["HostIp"], !ip.isEmpty { lines.append("          hostIP: \(KubeYAML.quote(ip))") }
                }
            }
        }
        let mounts = info["Mounts"] as? [[String: Any]] ?? []
        if !mounts.isEmpty {
            lines.append("      volumeMounts:")
            for mount in mounts {
                let type = kubeString(mount["Type"])
                guard type == "bind" || type == "volume" else { throw CLIError("cannot generate mount type \(type)") }
                let volumeName = "volume-\(volumes.count)"
                let target = kubeString(mount["Destination"])
                lines += ["        - name: \(volumeName)", "          mountPath: \(KubeYAML.quote(target))", "          readOnly: \((mount["RW"] as? Bool ?? true) ? "false" : "true")"]
                if type == "bind" {
                    volumes.append((volumeName, ["      hostPath:", "        path: \(KubeYAML.quote(kubeString(mount["Source"])))"]))
                } else {
                    let source = kubeString(mount["Name"])
                    guard !source.isEmpty else { throw CLIError("cannot generate unnamed volume") }
                    let volume = try engine.object("GET", "/volumes/\(podEscape(source))").value as? [String: Any] ?? [:]
                    let volumeLabels = volume["Labels"] as? [String: String] ?? [:]
                    if volumeLabels["dev.noodle.kube.ephemeral"] == "true" {
                        // Reuse one declaration when several containers mount the same emptyDir.
                        if let existing = ephemeralNames[source] {
                            lines[lines.count - 3] = "        - name: \(existing)"
                        } else {
                            ephemeralNames[source] = volumeName
                            volumes.append((volumeName, ["      emptyDir: {}"]))
                        }
                    } else { volumes.append((volumeName, ["      persistentVolumeClaim:", "        claimName: \(KubeYAML.quote(source))"])) }
                }
            }
        }
    }
    if !volumes.isEmpty {
        lines.append("  volumes:")
        for volume in volumes { lines.append("    - name: \(volume.name)"); lines += volume.source }
    }
    let yaml = lines.joined(separator: "\n") + "\n"
    // Verify the serializer's contract before writing anything to stdout.
    _ = try kubePlan(KubeYAML.parse(yaml))
    FileHandle.standardOutput.write(Data(yaml.utf8))
}
