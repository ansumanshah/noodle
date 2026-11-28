import Foundation
import NoodleCore

func k8sStart(_ args: [String]) {
    var apiPort: Int?
    var ports: String?
    var timeout = 240.0
    var json = false
    var i = 0
    func value() -> String { i += 1; guard i < args.count else { die("missing value for \(args[i - 1])", code: 2) }; return args[i] }
    while i < args.count {
        switch args[i] {
        case "--api-port": guard let n = Int(value()), (1...65535).contains(n) else { die("--api-port needs a port number", code: 2) }; apiPort = n
        case "--ports": ports = value()
        case "--timeout": guard let n = Double(value()), n > 0 else { die("--timeout needs seconds", code: 2) }; timeout = n
        case "--json": json = true
        default: usageDie("unknown option \(args[i])")
        }
        i += 1
    }
    requireDaemon()
    let existing = inspectCluster()
    // A container that merely shares the name is not ours to recreate or force-remove.
    requireManaged(existing)
    let wantAPI = apiPort ?? (existing.exists ? existing.apiPort : K8s.defaultAPIPort)
    let wantPorts = ports ?? (existing.exists ? existing.ports : K8s.defaultPorts)
    guard let list = K8s.parsePorts(wantPorts) else { die("--ports takes numbers and ranges such as 8080-8089,8443 (at most 256 ports)", code: 2) }
    if list.contains(wantAPI) { die("port \(wantAPI) is both the API port and a forwarded port", code: 2) }
    let folders = k8sSharedFolders(enabled: k8sSharedFoldersEnabled(clusterExists: existing.exists))
    let wantFolders = folders.joined(separator: "\n")

    var info = existing
    // A different pin, API port or port list recreates the container. The data volume is kept.
    if info.exists, info.image != K8s.image || info.apiPort != wantAPI || info.ports != wantPorts || info.sharedFolders != wantFolders {
        k8sStopLoadBalancerWatcher()
        note("Settings changed; recreating the cluster container (data is kept).")
        if dk(["rm", "-f", K8s.container], timeout: 60).code != 0 { die("could not remove the old cluster container") }
        info = ClusterInfo()
    }
    if info.running, nodeReady() {
        finishStart(apiPort: wantAPI, ports: wantPorts, already: true, json: json)
        return
    }
    if !info.exists {
        if dk(["image", "inspect", K8s.image], timeout: 20).code != 0 {
            note("Downloading k3s \(K8s.version) (pinned by digest, checked on pull)...")
            let r = dk(["pull", "--quiet", K8s.image], timeout: 900)
            guard r.code == 0 else { die("pull failed: \(r.out)") }
        }
        if dk(["network", "inspect", K8s.network], timeout: 20).code != 0 {
            let n = dk(["network", "create", "--subnet", K8s.subnet, K8s.network], timeout: 30)
            guard n.code == 0 else { die("cannot create the cluster network \(K8s.subnet): \(n.out)") }
        }
        var create = ["create", "--name", K8s.container, "--hostname", K8s.container, "--privileged", "--restart", "no",
                      "--network", K8s.network, "--ip", K8s.nodeIP,
                      "--label", K8s.labelPrefix + "managed=true",
                      "--label", K8s.labelPrefix + "image=" + K8s.image,
                      "--label", K8s.labelPrefix + "version=" + K8s.version,
                      "--label", K8s.labelPrefix + "api-port=\(wantAPI)",
                      "--label", K8s.labelPrefix + "ports=" + wantPorts,
                      "--label", K8s.labelPrefix + "shared-folders=" + wantFolders,
                      "--tmpfs", "/run", "--tmpfs", "/var/run",
                      "-v", K8s.volume + ":/var/lib/rancher/k3s",
                      "-p", "127.0.0.1:\(wantAPI):6443"]
        for p in list { create += ["-p", "127.0.0.1:\(p):\(p)"] }
        for f in folders { create += ["-v", "\(f):\(f)"] }
        create += [K8s.image, "server", "--node-name", "noodle", "--tls-san", "127.0.0.1", "--write-kubeconfig-mode", "644",
                   "--flannel-backend", "host-gw", "--disable", "traefik", "--disable", "metrics-server"]
        let c = dk(create, timeout: 60)
        guard c.code == 0 else { die("cannot create the cluster container: \(c.out)") }
    }
    if !info.running {
        k8sPrepareLoadBalancersForStart()
        note("Starting k3s \(K8s.version)...")
        let s = dk(["start", K8s.container], timeout: 120)
        guard s.code == 0 else { die("cannot start the cluster: \(s.out)") }
    }
    k8sStartLoadBalancerWatcher()
    let deadline = Date().addingTimeInterval(timeout)
    var wroteConfig = false
    while Date() < deadline {
        if !wroteConfig, let cfg = fetchKubeconfig(apiPort: wantAPI) {
            do { try writePrivate(cfg, to: K8s.kubeconfig(paths)); wroteConfig = true } catch { die("\(error.localizedDescription)") }
        }
        if wroteConfig, nodeReady() { finishStart(apiPort: wantAPI, ports: wantPorts, already: false, json: json); return }
        if !inspectCluster().running { die("the cluster container exited. See `docker --context noodle logs \(K8s.container)`.") }
        Thread.sleep(forTimeInterval: 2)
    }
    die("the node was not Ready after \(Int(timeout)) s. The cluster keeps starting in the background; check `noodle kubernetes status`.")
}

private func finishStart(apiPort: Int, ports: String, already: Bool, json: Bool) {
    k8sStartLoadBalancerWatcher()
    if let cfg = fetchKubeconfig(apiPort: apiPort) { try? writePrivate(cfg, to: K8s.kubeconfig(paths)) }
    if json {
        jsonOut(kubernetesStartJSON(alreadyRunning: already, apiPort: apiPort, kubeconfig: K8s.kubeconfig(paths).path, ports: ports))
        return
    }
    out(already ? "Kubernetes is already running." : "Kubernetes is ready.")
    out("  API server  https://127.0.0.1:\(apiPort) (this Mac only)")
    out("  kubeconfig  \(K8s.kubeconfig(paths).path)")
    out("  localhost   LoadBalancer ports published automatically (TCP and UDP)")
    if !ports.isEmpty { out("  NodePort    extra TCP ports \(ports)") }
    out("  use it      KUBECONFIG=\"\(K8s.kubeconfig(paths).path)\" kubectl get nodes")
}
