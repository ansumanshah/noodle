import Foundation
import NoodleCore

/// docker with a hard timeout (the process is killed when it passes).
@discardableResult
func dk(_ args: [String], timeout: Double = 60, errorOutput: FileHandle? = nil) -> (code: Int32, out: String) {
    guard let docker = which("docker") else { die("docker CLI not found. Run `noodle tools install` or put docker on PATH.", code: 127) }
    return runWithTimeout(docker, args, environment: engineDockerEnvironment, timeout: timeout, errorOutput: errorOutput)
}

struct ClusterInfo {
    var exists = false
    var running = false
    var labels: [String: String] = [:]
    var apiPort: Int { Int(labels[K8s.labelPrefix + "api-port"] ?? "") ?? K8s.defaultAPIPort }
    var managed: Bool { labels[K8s.labelPrefix + "managed"] == "true" }
    var ports: String { labels[K8s.labelPrefix + "ports"] ?? K8s.defaultPorts }
    var image: String { labels[K8s.labelPrefix + "image"] ?? "" }
    /// Approved folders bind-mounted at the same path, newline separated. Clusters made before shared folders have none.
    var sharedFolders: String { labels[K8s.labelPrefix + "shared-folders"] ?? "" }
}

/// One ownership check for start, stop, delete and kubeconfig import: a container that merely shares the name is not ours.
func requireManaged(_ info: ClusterInfo) {
    if info.exists, !info.managed {
        die("a container named \(K8s.container) exists but was not created by Noodle (no \(K8s.labelPrefix)managed label). Rename or remove it yourself, then run this again.")
    }
}

/// `strict` is for the machine-readable status: an unreadable reply or a failed inspect is an error, not "no cluster".
func inspectCluster(strict: Bool = false) -> ClusterInfo {
    let r = dk(["inspect", "--type", "container", K8s.container], timeout: 20)
    if strict, r.code != 0 {
        let lowered = r.out.lowercased()
        if !lowered.contains("no such container") && !lowered.contains("no such object") { die("cannot inspect Kubernetes: \(r.out)") }
    }
    guard r.code == 0, let data = r.out.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let o = arr.first else {
        if strict, r.code == 0 { die("invalid Kubernetes container response") }
        return ClusterInfo()
    }
    var info = ClusterInfo(exists: true)
    info.running = (o["State"] as? [String: Any])?["Running"] as? Bool ?? false
    info.labels = (o["Config"] as? [String: Any])?["Labels"] as? [String: String] ?? [:]
    return info
}

func nodeReady() -> Bool {
    let r = dk(["exec", K8s.container, "kubectl", "get", "nodes", "--no-headers"], timeout: 20)
    return r.code == 0 && r.out.split(separator: "\n").contains { $0.split(separator: " ").dropFirst().first == "Ready" }
}

func requireDaemon() {
    guard ping() else { die("the Noodle engine is not running. Start it with `noodle start`.", code: 3) }
}

func writePrivate(_ text: String, to url: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tmp = url.appendingPathExtension("tmp-\(getpid())")
    try? fm.removeItem(at: tmp)
    guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
        throw NSError(domain: "noodle", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(tmp.path)"])
    }
    if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: url)
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func fetchKubeconfig(apiPort: Int) -> String? {
    requireManaged(inspectCluster())
    let r = dk(["exec", K8s.container, "cat", "/etc/rancher/k3s/k3s.yaml"], timeout: 20)
    guard r.code == 0, r.out.contains("client-certificate-data") else { return nil }
    return K8s.rename(kubeconfig: r.out, server: "https://127.0.0.1:\(apiPort)") + "\n"
}
