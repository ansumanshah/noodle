import Foundation
import NoodleCore

private func kubeInfraName(_ plan: KubeWorkload) -> String { "noodle-kube-\(plan.name)-infra" }

func kubePlay(_ plans: [KubeWorkload], engine: EngineEndpoint) throws {
    var created: [String] = [], createdVolumes: [String] = []
    do {
        // Check every name before creating anything, including names across workloads.
        var names = Set<String>()
        let ephemeral = plans.flatMap { $0.volumes.filter { $0.value }.map { $0.key } }
        let persistent = Set(plans.flatMap { $0.volumes.filter { !$0.value }.map { $0.key } })
        guard Set(ephemeral).count == ephemeral.count, Set(ephemeral).isDisjoint(with: persistent) else { throw CLIError("volume names collide across Kubernetes resources") }
        for plan in plans {
            if plan.containers.count > 1, try engine.exists("/containers/\(podEscape(kubeInfraName(plan)))/json") {
                throw CLIError("container \(kubeInfraName(plan)) already exists; use --down first")
            }
            for c in plan.containers {
                guard names.insert(c.name).inserted, try !engine.exists("/containers/\(podEscape(c.name))/json") else { throw CLIError("container \(c.name) already exists; use --down first") }
            }
        }
        for plan in plans {
            for (name, ephemeral) in plan.volumes.sorted(by: { $0.key < $1.key }) {
                let exists = try engine.exists("/volumes/\(podEscape(name))")
                if ephemeral && exists { throw CLIError("emptyDir volume \(name) already exists") }
                if !exists {
                    try engine.call("POST", "/volumes/create", json: ["Name": name, "Labels": [kubeOwnerLabel: plan.owner, "dev.noodle.kube.ephemeral": String(ephemeral)]])
                    createdVolumes.append(name)
                }
            }
            var anchor: String?
            // Every hostPort belongs to the shared network namespace's first container.
            var allBindings: [String: [[String: String]]] = [:]
            for c in plan.containers {
                let host = c.body["HostConfig"] as? [String: Any] ?? [:]
                for (key, bindings) in host["PortBindings"] as? [String: [[String: String]]] ?? [:] { allBindings[key, default: []] += bindings }
            }
            func ensureImage(_ image: String) throws {
                if try !engine.exists("/images/\(podEscape(image))/json") {
                    let reply = try engine.call("POST", "/images/create?fromImage=\(podEscape(image))")
                    for line in String(decoding: reply.body, as: UTF8.self).split(separator: "\n") {
                        if let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["error"] { throw CLIError("image pull: \(message)") }
                    }
                }
            }
            // With several containers the namespace is owned by a dedicated sleeping container, so a
            // short-lived first container cannot take the shared network namespace with it. It carries the
            // owner label (for --down) but not the pod label, so it never counts as a workload member.
            let sharesNamespace = plan.containers.count > 1
            if sharesNamespace {
                try ensureImage(podInfraImage)
                let infra: [String: Any] = ["Image": podInfraImage, "Entrypoint": ["/bin/sleep"], "Cmd": ["infinity"],
                    "ExposedPorts": Dictionary(uniqueKeysWithValues: allBindings.keys.map { ($0, [String: Any]()) }),
                    "HostConfig": ["Init": true, "PortBindings": allBindings],
                    "Labels": [kubeOwnerLabel: plan.owner, "dev.noodle.kube.infra": "true"]]
                let reply = try engine.object("POST", "/containers/create?name=\(podEscape(kubeInfraName(plan)))", json: infra)
                guard let id = (reply.value as? [String: Any])?["Id"] as? String else { throw CLIError("missing infra container ID") }
                created.append(id)
                try engine.call("POST", "/containers/\(podEscape(id))/start")
                anchor = id
            }
            for c in plan.containers {
                var body = c.body
                var host = body["HostConfig"] as? [String: Any] ?? [:]
                if let anchor { host["NetworkMode"] = "container:\(anchor)"; host["PortBindings"] = [String: Any]() }
                else { host["PortBindings"] = allBindings }
                body["HostConfig"] = host
                try ensureImage(kubeString(body["Image"]))
                let reply = try engine.object("POST", "/containers/create?name=\(podEscape(c.name))", json: body)
                guard let id = (reply.value as? [String: Any])?["Id"] as? String else { throw CLIError("missing container ID") }
                created.append(id)
                try engine.call("POST", "/containers/\(podEscape(id))/start")
                if anchor == nil { anchor = id }
                out(c.name)
            }
        }
    } catch {
        for id in created.reversed() { _ = try? engine.call("DELETE", "/containers/\(podEscape(id))?force=1", ok: [404]) }
        for name in createdVolumes.reversed() { _ = try? engine.call("DELETE", "/volumes/\(podEscape(name))", ok: [404]) }
        throw error
    }
}
