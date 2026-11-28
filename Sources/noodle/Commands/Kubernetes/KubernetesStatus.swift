import Foundation
import NoodleCore

/// Machine-readable snapshot for the app. Never reads or prints kubeconfig credentials.
/// Non-ready states are successful snapshots; transport and pod-query failures stay explicit.
func k8sJSONStatus() {
    let daemonRunning = ping()
    let info = daemonRunning ? inspectCluster(strict: true) : ClusterInfo()
    let ready = info.running && nodeReady()
    var pods: [[String: Any]] = []
    var podsError = ""
    if info.running {
        let result = dk(["exec", K8s.container, "kubectl", "get", "pods", "--all-namespaces", "-o", "json", "--request-timeout=10s"], timeout: 20)
        if result.code == 0, let data = result.out.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["items"] as? [[String: Any]] {
            pods = items.map { item in
                let meta = item["metadata"] as? [String: Any] ?? [:]
                let status = item["status"] as? [String: Any] ?? [:]
                let containers = status["containerStatuses"] as? [[String: Any]] ?? []
                let spec = item["spec"] as? [String: Any] ?? [:]
                let total = (spec["containers"] as? [[String: Any]])?.count ?? 0
                return ["namespace": meta["namespace"] as? String ?? "default",
                        "name": meta["name"] as? String ?? "unknown",
                        "phase": status["phase"] as? String ?? "Unknown",
                        "ready": "\(containers.filter { $0["ready"] as? Bool == true }.count)/\(total)",
                        "restarts": containers.reduce(0) { $0 + ($1["restartCount"] as? Int ?? 0) }]
            }
        } else { podsError = result.out.isEmpty ? "Could not load pods." : result.out }
    }
    let snapshot: [String: Any] = [
        "schemaVersion": 1,
        "daemonRunning": daemonRunning, "exists": info.exists, "running": info.running, "ready": ready,
        "hasData": info.exists || FileManager.default.fileExists(atPath: K8s.directory(paths).path),
        "version": info.labels[K8s.labelPrefix + "version"] ?? K8s.version,
        "apiPort": info.apiPort, "ports": K8s.parsePorts(info.ports) ?? [],
        "kubeconfig": K8s.kubeconfig(paths).path,
        "hasKubeconfig": FileManager.default.fileExists(atPath: K8s.kubeconfig(paths).path),
        "pods": pods, "podsError": podsError,
    ]
    out(jsonLine(snapshot))
}

func k8sStatus() {
    let kc = K8s.kubeconfig(paths)
    guard ping() else { note("Kubernetes: stopped (the Noodle engine is not running)"); exit(3) }
    let info = inspectCluster()
    guard info.exists else { note("Kubernetes: not created. `noodle kubernetes start` creates and starts it."); exit(3) }
    guard info.running else {
        note("Kubernetes: stopped (data kept)")
        note("  start it    noodle kubernetes start")
        exit(3)
    }
    let ready = nodeReady()
    out("Kubernetes: \(ready ? "running" : "starting") (k3s \(info.labels[K8s.labelPrefix + "version"] ?? K8s.version))")
    out("  node        \(ready ? "Ready" : "not Ready yet")")
    out("  API server  https://127.0.0.1:\(info.apiPort)")
    out("  kubeconfig  \(kc.path)")
    out("  localhost   LoadBalancer ports published automatically (TCP and UDP)")
    if !info.ports.isEmpty { out("  NodePort    extra TCP ports \(info.ports)") }
    k8sLoadBalancerStatus()
    exit(ready ? 0 : 3)
}
