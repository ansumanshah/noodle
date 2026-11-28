import Foundation
import NoodleCore

/// Remove every selected workload's containers first, then their volumes: a claim can be mounted by
/// a container that belongs to a later workload, and deleting the volume early would abort midway.
func kubeDown(_ plans: [KubeWorkload], engine: EngineEndpoint) throws {
    let owners = Set(plans.map(\.owner))
    let containers = try engine.containers().sorted {
        let left = ($0["HostConfig"] as? [String: Any])?["NetworkMode"] as? String ?? ""
        let right = ($1["HostConfig"] as? [String: Any])?["NetworkMode"] as? String ?? ""
        return left.hasPrefix("container:") && !right.hasPrefix("container:")
    }
    for c in containers {
        let labels = c["Labels"] as? [String: String] ?? [:]
        if let owner = labels[kubeOwnerLabel], owners.contains(owner), let id = c["Id"] as? String {
            try engine.call("DELETE", "/containers/\(podEscape(id))?force=1", ok: [404])
        }
    }
    for v in try engine.volumes() {
        let labels = v["Labels"] as? [String: String] ?? [:]
        if let owner = labels[kubeOwnerLabel], owners.contains(owner), let name = v["Name"] as? String {
            try engine.call("DELETE", "/volumes/\(podEscape(name))", ok: [404])
        }
    }
    for plan in plans { out("Removed \(plan.name); pre-existing volumes retained") }
}
