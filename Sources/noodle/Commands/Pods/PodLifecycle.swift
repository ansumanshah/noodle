import Foundation

private func podStopContainer(_ container: PodContainer, _ endpoint: EngineEndpoint) throws {
    guard container.running else { return }
    // A paused process cannot receive SIGTERM until resumed.
    if container.state == "paused" { try endpoint.call("POST", podRoute(container) + "/unpause") }
    try endpoint.call("POST", podRoute(container) + "/stop?t=10", ok: [304])
}

func podStartContainer(_ container: PodContainer, _ endpoint: EngineEndpoint) throws {
    if container.state == "paused" { try endpoint.call("POST", podRoute(container) + "/unpause"); return }
    guard !container.running else { return }
    try endpoint.call("POST", podRoute(container) + "/start", ok: [304])
}

/// Stopping an AutoRemove member deletes its writable layer and configuration.
/// Refuse before touching any container rather than silently lose a member during
/// restart or recovery of an externally stopped namespace owner.
func podRequireRestartable(_ members: [PodContainer], _ endpoint: EngineEndpoint) throws {
    for member in members {
        let config = try endpoint.inspect("containers", member.id)["HostConfig"] as? PodJSON
        if config?["AutoRemove"] as? Bool == true {
            throw CLIError("cannot restart or recover pod while member \(member.name) uses --rm; stop or remove that member first")
        }
    }
}

func podStop(_ pod: Pod, _ endpoint: EngineEndpoint) throws {
    for member in pod.members.reversed() { try podStopContainer(member, endpoint) }
    try podStopContainer(pod.infra, endpoint)
}

func podStart(_ pod: Pod, _ endpoint: EngineEndpoint) throws {
    if !pod.infra.running {
        // If the owner was stopped separately, running members still hold its
        // old namespace. Stop them before making a new owner namespace.
        try podRequireRestartable(pod.members.filter(\.running), endpoint)
        for member in pod.members.reversed() { try podStopContainer(member, endpoint) }
    }
    try podStartContainer(pod.infra, endpoint)
    let refreshed = try podFind(pod.infra.id, endpoint)
    for member in refreshed.members { try podStartContainer(member, endpoint) }
}
