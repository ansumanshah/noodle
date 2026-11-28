import Foundation
import NoodleCore

func kubePlan(_ documents: [[String: Any]]) throws -> [KubeWorkload] {
    var maps: [String: [String: Any]] = [:]
    for doc in documents {
        let kind = kubeString(doc["kind"])
        guard ["Pod", "Deployment", "ConfigMap", "PersistentVolumeClaim"].contains(kind) else {
            throw CLIError("unsupported kind: \(kind)")
        }
        kubeFields(doc, ["apiVersion", "kind", "metadata", "spec", "data"], kind)
        let meta = doc["metadata"] as? [String: Any] ?? [:]
        kubeFields(meta, ["name", "namespace", "labels", "annotations"], "\(kind).metadata")
        let name = try kubeName(meta["name"], "\(kind).metadata.name")
        if kind == "ConfigMap" {
            kubeFields(doc, ["apiVersion", "kind", "metadata", "data"], kind)
            let key = "\(kubeString(meta["namespace"]))|\(name)"
            guard maps[key] == nil else { throw CLIError("duplicate ConfigMap \(name)") }
            maps[key] = doc["data"] as? [String: Any] ?? [:]
        }
    }
    var plans: [KubeWorkload] = [], owners = Set<String>()
    for doc in documents {
        let kind = kubeString(doc["kind"])
        guard kind == "Pod" || kind == "Deployment" else { continue }
        let meta = doc["metadata"] as? [String: Any] ?? [:]
        let name = try kubeName(meta["name"], "metadata.name")
        let namespace = kubeString(meta["namespace"])
        let owner = "\(kind)/\(namespace)/\(name)"
        guard owners.insert(owner).inserted else { throw CLIError("duplicate Kubernetes resource \(name)") }
        var spec = doc["spec"] as? [String: Any] ?? [:]
        if kind == "Deployment" {
            kubeFields(spec, ["replicas", "selector", "template"], "Deployment.spec")
            guard spec["replicas"] == nil || kubeString(spec["replicas"]) == "1" else { throw CLIError("Deployment replicas must be 1") }
            let template = spec["template"] as? [String: Any] ?? [:]
            kubeFields(template, ["metadata", "spec"], "Deployment.spec.template")
            kubeFields(template["metadata"] as? [String: Any] ?? [:], ["name", "labels", "annotations"], "Deployment.spec.template.metadata")
            spec = template["spec"] as? [String: Any] ?? [:]
        }
        kubeFields(spec, ["containers", "volumes", "restartPolicy"], "\(name).spec")
        var sources: [String: (String, String)] = [:], volumes: [String: Bool] = [:]
        var readOnlySources = Set<String>()
        var createDirectories = Set<String>()
        for v in spec["volumes"] as? [[String: Any]] ?? [] {
            kubeFields(v, ["name", "hostPath", "emptyDir", "persistentVolumeClaim"], "volume")
            let vn = try kubeName(v["name"], "volume.name")
            guard sources[vn] == nil else { throw CLIError("duplicate volume \(vn)") }
            guard ["hostPath", "emptyDir", "persistentVolumeClaim"].filter({ v[$0] != nil }).count == 1 else { throw CLIError("volume \(vn) requires one supported source") }
            if let host = v["hostPath"] as? [String: Any] {
                kubeFields(host, ["path", "type"], "hostPath")
                let path = kubeString(host["path"])
                guard path.hasPrefix("/"), !path.contains(":"), !path.contains("\n") else { throw CLIError("hostPath must be absolute without colon or newline") }
                let type = kubeString(host["type"])
                guard ["", "Directory", "DirectoryOrCreate", "File"].contains(type) else { throw CLIError("unsupported hostPath type \(type)") }
                if type == "DirectoryOrCreate" { createDirectories.insert(vn) }
                sources[vn] = ("bind", path)
            } else if let pvc = v["persistentVolumeClaim"] as? [String: Any] {
                kubeFields(pvc, ["claimName", "readOnly"], "persistentVolumeClaim")
                let claim = try kubeName(pvc["claimName"], "claimName")
                sources[vn] = ("volume", claim); volumes[claim] = false
                if kubeString(pvc["readOnly"]) == "true" { readOnlySources.insert(vn) }
            } else {
                let empty = v["emptyDir"] as? [String: Any] ?? [:]
                guard empty.isEmpty else { throw CLIError("emptyDir options are unsupported") }
                let volume = "\(name)-\(vn)-empty"
                sources[vn] = ("volume", volume); volumes[volume] = true
            }
        }
        guard let containers = spec["containers"] as? [[String: Any]], !containers.isEmpty else { throw CLIError("\(name) requires containers") }
        var plan = KubeWorkload(name: name, owner: owner, containers: [], volumes: volumes)
        var names = Set<String>()
        for c in containers {
            kubeFields(c, ["name", "image", "env", "envFrom", "ports", "command", "args", "volumeMounts", "workingDir"], "container")
            let cn = try kubeName(c["name"], "container.name")
            guard names.insert(cn).inserted else { throw CLIError("duplicate container \(cn)") }
            guard let image = c["image"] as? String, !image.isEmpty else { throw CLIError("container \(cn) requires image") }
            var values: [String: String] = [:]
            func config(_ ref: [String: Any]) throws -> [String: Any] {
                let key = "\(namespace)|\(kubeString(ref["name"]))"
                guard let data = maps[key] else { throw CLIError("ConfigMap \(kubeString(ref["name"])) is missing from the file") }
                return data
            }
            for from in c["envFrom"] as? [[String: Any]] ?? [] {
                kubeFields(from, ["configMapRef", "prefix"], "envFrom")
                guard let ref = from["configMapRef"] as? [String: Any] else { throw CLIError("only ConfigMap envFrom is supported") }
                kubeFields(ref, ["name"], "configMapRef")
                for (key, value) in try config(ref) { values[kubeString(from["prefix"]) + key] = kubeString(value) }
            }
            for e in c["env"] as? [[String: Any]] ?? [] {
                kubeFields(e, ["name", "value", "valueFrom"], "env")
                let key = kubeString(e["name"])
                guard !key.isEmpty, !key.contains("=") else { throw CLIError("invalid environment name") }
                if let from = e["valueFrom"] as? [String: Any] {
                    kubeFields(from, ["configMapKeyRef"], "valueFrom")
                    guard let ref = from["configMapKeyRef"] as? [String: Any], let value = try config(ref)[kubeString(ref["key"])] else { throw CLIError("only existing ConfigMap keys are supported in valueFrom") }
                    kubeFields(ref, ["name", "key"], "configMapKeyRef")
                    values[key] = kubeString(value)
                } else { values[key] = kubeString(e["value"]) }
            }
            var bindings: [String: [[String: String]]] = [:], exposed: [String: Any] = [:]
            for port in c["ports"] as? [[String: Any]] ?? [] {
                kubeFields(port, ["name", "containerPort", "hostPort", "protocol", "hostIP"], "port")
                guard let number = Int(kubeString(port["containerPort"])), (1...65535).contains(number) else { throw CLIError("invalid containerPort") }
                let proto = kubeString(port["protocol"] ?? "TCP").lowercased()
                guard ["tcp", "udp"].contains(proto) else { throw CLIError("unsupported port protocol \(proto)") }
                let key = "\(number)/\(proto)"; exposed[key] = [:]
                if let value = port["hostPort"] {
                    guard let hp = Int(kubeString(value)), (1...65535).contains(hp) else { throw CLIError("invalid hostPort") }
                    bindings[key, default: []].append(["HostPort": String(hp), "HostIp": port["hostIP"] == nil ? "127.0.0.1" : kubeString(port["hostIP"])])
                }
            }
            var mounts: [[String: Any]] = []
            for mount in c["volumeMounts"] as? [[String: Any]] ?? [] {
                kubeFields(mount, ["name", "mountPath", "readOnly"], "volumeMount")
                guard let source = sources[kubeString(mount["name"])] else { throw CLIError("unknown volumeMount") }
                let target = kubeString(mount["mountPath"])
                guard target.hasPrefix("/") else { throw CLIError("mountPath must be absolute") }
                var dockerMount: [String: Any] = ["Type": source.0, "Source": source.1, "Target": target, "ReadOnly": kubeString(mount["readOnly"]) == "true" || readOnlySources.contains(kubeString(mount["name"]))]
                if createDirectories.contains(kubeString(mount["name"])) { dockerMount["BindOptions"] = ["CreateMountpoint": true] }
                mounts.append(dockerMount)
            }
            var host: [String: Any] = ["Mounts": mounts, "PortBindings": bindings]
            if let policy = spec["restartPolicy"] as? String {
                guard ["Always", "Never", "OnFailure"].contains(policy) else { throw CLIError("invalid restartPolicy") }
                host["RestartPolicy"] = ["Name": ["Always": "always", "Never": "no", "OnFailure": "on-failure"][policy]!]
            }
            var body: [String: Any] = ["Image": image, "Env": values.keys.sorted().map { "\($0)=\(values[$0]!)" }, "ExposedPorts": exposed, "HostConfig": host,
                "Labels": [podLabel: name, kubeOwnerLabel: owner, "dev.noodle.kube.container": cn, "dev.noodle.kube.namespace": namespace]]
            for (yaml, docker) in [("command", "Entrypoint"), ("args", "Cmd")] {
                if let value = c[yaml] {
                    guard let list = value as? [String] else { throw CLIError("\(yaml) must be a string array") }
                    body[docker] = list
                }
            }
            if c["command"] != nil && c["args"] == nil { body["Cmd"] = [String]() }
            if let directory = c["workingDir"] { body["WorkingDir"] = directory }
            plan.containers.append(("\(name)-\(cn)", body))
        }
        plans.append(plan)
    }
    // PVC documents also materialize named volumes when no container mounts them.
    for doc in documents where kubeString(doc["kind"]) == "PersistentVolumeClaim" {
        let meta = doc["metadata"] as? [String: Any] ?? [:]
        let name = try kubeName(meta["name"], "PersistentVolumeClaim.metadata.name")
        let spec = doc["spec"] as? [String: Any] ?? [:]
        for key in spec.keys.sorted() { err("warning: PersistentVolumeClaim.spec.\(key) ignored; using a local named volume") }
        plans.append(KubeWorkload(name: name, owner: "PersistentVolumeClaim/\(kubeString(meta["namespace"]))/\(name)", containers: [], volumes: [name: false]))
    }
    return plans
}
