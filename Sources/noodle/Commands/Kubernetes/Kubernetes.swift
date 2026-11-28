import Foundation
import NoodleCore

// noodle kubernetes: managed single-node k3s. The CLI starts a detached watcher that mirrors cluster services to the host; `stop` and `delete` wait for it.
// Everything here is the CLI driving the Docker API through the docker client: the daemon gains no code,
// no dependency and no timer. Nothing runs and nothing is downloaded until `start`.

func cmdKubernetes(_ args: [String]) {
    let rest = Array(args.dropFirst())
    if let action = args.first, ["stop", "kubeconfig"].contains(action) {
        guard rest.isEmpty else { die("usage: noodle kubernetes \(action)", code: 2) }
    }
    switch args.first {
    case "start": k8sStart(rest)
    case "_watch-loadbalancers": k8sWatchLoadBalancers()
    case "stop": k8sStop()
    case "status":
        guard rest.isEmpty || rest == ["--json"] else { die("usage: noodle kubernetes status [--json]", code: 2) }
        if rest == ["--json"] { k8sJSONStatus() } else { k8sStatus() }
    case "delete": k8sDelete(rest)
    case "kubeconfig": k8sKubeconfig()
    case "use-context": k8sUseContext(rest)
    case "shared-folders": k8sSharedFoldersCommand(rest)
    default:
        die("usage: noodle kubernetes start [--api-port N] [--ports LIST] [--timeout SECONDS] [--json] | stop | status [--json] | delete [--yes] | kubeconfig | use-context [--remove] [--kubeconfig PATH] | shared-folders [on|off]", code: 2)
    }
}
