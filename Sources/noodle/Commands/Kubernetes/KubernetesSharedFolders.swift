import Foundation
import NoodleCore

// "Let Kubernetes use your shared folders". The daemon owns the switch
// because flipping it restarts the workload VM; the CLI only bind-mounts approved folders into the node.

private struct SharedFoldersReply: Codable { var Enabled: Bool?; var Restarted: Bool?; var Restart: Bool? }

private func sharedFoldersRequest(_ enable: Bool?, restart: Bool = false) -> SharedFoldersReply {
    let body = enable.map { try? JSONEncoder().encode(SharedFoldersReply(Enabled: $0, Restart: restart ? true : nil)) } ?? nil
    do {
        let data = try DevCommand.request(enable == nil ? "GET" : "POST", "/noodle/kubernetes/shared-folders", body: body)
        return try JSONDecoder().decode(SharedFoldersReply.self, from: data)
    } catch { die(error, prefix: "cannot read or change the Kubernetes shared folders setting: ") }
}

/// First `start` decides: on for a new cluster (one line says so), off for a cluster that already exists.
func k8sSharedFoldersEnabled(clusterExists: Bool) -> Bool {
    if let on = sharedFoldersRequest(nil).Enabled { return on }
    let on = !clusterExists
    _ = sharedFoldersRequest(on)
    note(on ? "Kubernetes can use your shared folders (noodle share list) through hostPath at the same path. Turn it off with: noodle kubernetes shared-folders off"
           : "Kubernetes does not use your shared folders for this existing cluster. Turn it on with: noodle kubernetes shared-folders on")
    return on
}

func k8sSharedFolders(enabled: Bool) -> [String] {
    enabled ? VMSettings.load(paths: paths).kubernetesNodeFolders : []
}

/// `noodle share remove --restart`: end access to a removed folder now. The workload VM keeps every share it handed
/// out until it stops, and the k3s node keeps its bind until it is recreated.
func k8sRevokeRemovedFolder() {
    requireDaemon()
    let info = inspectCluster()
    if sharedFoldersRequest(true, restart: true).Restarted == true {
        note("Restarted the privileged containers VM; containers running in it were stopped.")
    }
    if info.exists, info.managed, info.running {
        note("Recreating the Kubernetes node without the removed folder...")
        k8sStart([])
    }
}

func k8sSharedFoldersCommand(_ args: [String]) {
    guard args.isEmpty || args == ["on"] || args == ["off"] else { die("usage: noodle kubernetes shared-folders [on|off]", code: 2) }
    requireDaemon()
    switch args {
    case []:
        out(sharedFoldersRequest(nil).Enabled == true ? "on" : "off")
    case ["on"], ["off"]:
        let info = inspectCluster()
        let r = sharedFoldersRequest(args == ["on"])
        out(args == ["on"] ? "Kubernetes and privileged containers can now use your approved folders." : "Kubernetes and privileged containers no longer get Mac folders.")
        if r.Restarted == true { note("Restarted the privileged containers VM to apply it; containers running in it were stopped.") }
        if info.exists, info.managed {
            if info.running {
                note("Restarting Kubernetes with the new setting...")
                k8sStart([])
            } else {
                note("The cluster picks this up at its next `noodle kubernetes start`.")
            }
        }
    default: break
    }
}
