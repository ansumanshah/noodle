import Foundation

/// Demo actions stay in memory and never invoke the CLI or touch kubeconfig.
enum DemoKubernetes {
    static var initial: KubernetesSnapshot {
        let empty = DemoFlags.empty
        let down = DemoFlags.has("--demo-down")
        return KubernetesSnapshot(daemonRunning: !down, exists: !empty, running: !empty && !down,
                                  ready: !empty && !down, hasData: !empty, version: "k3s (demo)",
                                  apiPort: 6443, ports: Array(8080...8089) + [8443] + Array(30000...30009),
                                  kubeconfig: "~/.local/share/noodle/kubernetes/kubeconfig", hasKubeconfig: !empty,
                                  pods: empty || down ? [] : pods, podsError: "")
    }

    static let pods = [
        KubernetesPod(namespace: "kube-system", name: "coredns-7c65d6cfc9-demo", phase: "Running", ready: "1/1", restarts: 0),
        KubernetesPod(namespace: "kube-system", name: "local-path-provisioner-demo", phase: "Running", ready: "1/1", restarts: 0),
        KubernetesPod(namespace: "default", name: "web-6d7f8b9c-demo", phase: "Running", ready: "1/1", restarts: 1),
    ]

    static func applying(_ action: KubernetesStore.Action, to snapshot: KubernetesSnapshot) -> KubernetesSnapshot {
        var next = snapshot
        switch action {
        case .start, .reset:
            next.exists = true; next.hasData = true; next.running = true; next.ready = true
            next.hasKubeconfig = true; next.pods = action == .reset ? Array(pods.prefix(2)) : pods
        case .stop:
            next.running = false; next.ready = false; next.pods = []
        case .remove:
            next.exists = false; next.hasData = false; next.running = false; next.ready = false
            next.hasKubeconfig = false; next.pods = []
        case .context: break
        }
        return next
    }
}
