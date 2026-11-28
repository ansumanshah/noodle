import Darwin
import Foundation
import NoodleCore

private var lbDirectory: URL { K8s.directory(paths) }
private var lbStop: URL { lbDirectory.appendingPathComponent("loadbalancer.stop") }
private var lbStatus: URL { lbDirectory.appendingPathComponent("loadbalancer.status") }
private var lbExecutable: String { Bundle.main.executableURL?.path ?? selfDirectory() + "/noodle" }

/// The lock, rather than a PID file, identifies a live helper. Never signal a reused PID.
private func lbLock(create: Bool = false) -> Int32 {
    if create {
        try? FileManager.default.createDirectory(at: lbDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    return open(lbDirectory.appendingPathComponent("loadbalancer.lock").path,
                O_RDWR | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
}

private func lbActive() -> Bool {
    let fd = lbLock()
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
    return errno == EWOULDBLOCK
}

func k8sStartLoadBalancerWatcher() {
    if lbActive() { return }
    try? FileManager.default.removeItem(at: lbStop)
    try? FileManager.default.removeItem(at: lbStatus)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lbExecutable)
    process.arguments = ["kubernetes", "_watch-loadbalancers"]
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { die("cannot start LoadBalancer watcher: \(error.localizedDescription)") }
    guard waitFor({ lbActive() }, seconds: 5) else { die("LoadBalancer watcher did not start; run `noodle kubernetes start` to retry") }
}

func k8sStopLoadBalancerWatcher() {
    guard lbActive() else { return }
    do { try Data().write(to: lbStop) } catch { die("cannot stop LoadBalancer watcher: \(error.localizedDescription)") }
    // A request already in flight has a 20s hard deadline. The worker checks this
    // marker between requests, so it cannot keep publishing while stop/delete proceeds.
    guard waitFor({ !lbActive() }, seconds: 45) else { die("LoadBalancer watcher did not stop; retry the command") }
}

func k8sLoadBalancerStatus() {
    guard lbActive() else {
        out("  LoadBalancer watcher stopped; run `noodle kubernetes start` to resume discovery")
        return
    }
    if let status = try? String(contentsOf: lbStatus, encoding: .utf8), !status.isEmpty {
        for line in status.split(separator: "\n") { out("  LoadBalancer \(line)") }
    } else { out("  LoadBalancer discovering services") }
}

private func lbWriteStatus(_ lines: [String]) {
    let text = lines.isEmpty ? "no services\n" : lines.joined(separator: "\n") + "\n"
    guard (try? String(contentsOf: lbStatus, encoding: .utf8)) != text else { return }
    // The containing directory is private. Atomic snapshots let status read without
    // waiting for kubectl, and never expose a half-written report.
    try? Data(text.utf8).write(to: lbStatus, options: .atomic)
}

private func lbPinned(_ node: [String: Any]) -> Set<String> {
    let labels = (node["Config"] as? [String: Any])?["Labels"] as? [String: String] ?? [:]
    return Set((K8s.parsePorts(labels[K8s.labelPrefix + "ports"] ?? K8s.defaultPorts) ?? []).map { "\($0)/tcp" })
}

private func lbPublished(_ node: [String: Any]) -> Set<String> {
    let bindings = (node["HostConfig"] as? [String: Any])?["PortBindings"] as? [String: Any] ?? [:]
    return Set(bindings.compactMap { key, value in
        let number = String(key.prefix(while: { $0 != "/" }))
        return (value as? [[String: String]] ?? []).contains {
            $0["HostIp"] == "127.0.0.1" && $0["HostPort"] == number
        } ? key : nil
    })
}

private func lbEdit(_ id: String, _ key: String, removing: Bool) -> (code: Int32, out: String) {
    let number = String(key.prefix(while: { $0 != "/" }))
    return runWithTimeout(lbExecutable, ["container", "edit", id, removing ? "--unpublish" : "--publish",
                                "127.0.0.1:\(number):\(key)"], timeout: 20)
}

/// Services are durable in k3s. Rebuild dynamic publications after a stopped node
/// starts, so an occupied service port cannot prevent the entire cluster booting.
/// The API and explicitly configured ports retain their ordinary start semantics.
func k8sPrepareLoadBalancersForStart() {
    k8sStopLoadBalancerWatcher()
    let inspected = dk(["inspect", "--type", "container", K8s.container], timeout: 20)
    guard inspected.code == 0, let data = inspected.out.data(using: .utf8),
          let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let node = objects.first, let id = node["Id"] as? String,
          ((node["Config"] as? [String: Any])?["Labels"] as? [String: String])?[K8s.labelPrefix + "managed"] == "true" else {
        die("cannot inspect LoadBalancer publications before start: \(inspected.out)")
    }
    guard (node["State"] as? [String: Any])?["Running"] as? Bool != true else { return }
    for key in lbPublished(node).subtracting(lbPinned(node)).subtracting(["6443/tcp"]).sorted() {
        let result = lbEdit(id, key, removing: true)
        guard result.code == 0 else { die("cannot reset LoadBalancer \(key) before start: \(result.out)") }
    }
}

/// Only the CLI helper polls; no daemon code, timer or dependency is added. A
/// stopped/missing node or disconnected daemon ends the helper, releasing its lock.
func k8sWatchLoadBalancers() {
    _ = setsid()
    let fd = lbLock(create: true)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    let fm = FileManager.default
    func stopping() -> Bool { fm.fileExists(atPath: lbStop.path) }
    // Poll every 10 s, backing off to 60 s while nothing changes. A blocked port keeps the 10 s pace, so freeing it publishes soon.
    var interval: TimeInterval = 10
    var lastWanted: Set<String>?, lastPublished: Set<String>?
    while !stopping() {
        let inspected = dk(["inspect", "--type", "container", K8s.container], timeout: 20)
        guard inspected.code == 0,
              let data = inspected.out.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let node = objects.first,
              (node["State"] as? [String: Any])?["Running"] as? Bool == true else { return }
        if stopping() { return }
        let labels = (node["Config"] as? [String: Any])?["Labels"] as? [String: String] ?? [:]
        guard labels[K8s.labelPrefix + "managed"] == "true", let id = node["Id"] as? String else { return }
        let apiPort = Int(labels[K8s.labelPrefix + "api-port"] ?? "") ?? K8s.defaultAPIPort
        let pinned = lbPinned(node)
        let services = dk(["exec", id, "kubectl", "get", "services", "--all-namespaces", "-o", "json", "--request-timeout=10s"], timeout: 20)
        if stopping() { return }
        if services.code == 0, let data = services.out.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = list["items"] as? [[String: Any]] {
            var wanted = Set<String>()
            var report: [String] = []
            for service in items {
                guard let spec = service["spec"] as? [String: Any], spec["type"] as? String == "LoadBalancer" else { continue }
                for port in spec["ports"] as? [[String: Any]] ?? [] {
                    guard let number = port["port"] as? Int, (1...65535).contains(number) else { continue }
                    let proto = (port["protocol"] as? String ?? "TCP").lowercased()
                    let key = "\(number)/\(proto)"
                    guard proto == "tcp" || proto == "udp" else {
                        report.append("\(key): blocked (unsupported protocol)"); continue
                    }
                    guard proto != "tcp" || (number != apiPort && number != 6443) else {
                        report.append("\(key): blocked (reserved for the Kubernetes API)"); continue
                    }
                    wanted.insert(key)
                }
            }
            // Inspect is the durable record of publications this helper owns.
            let published = lbPublished(node)
            for key in published.subtracting(wanted).subtracting(pinned).subtracting(["6443/tcp"]).sorted() {
                if stopping() { return }
                let result = lbEdit(id, key, removing: true)
                if result.code != 0 { report.append("\(key): removal blocked (\(result.out))") }
            }
            var anyBlocked = false
            for key in wanted.sorted() {
                if stopping() { return }
                if published.contains(key) { report.append("\(key): published"); continue }
                let result = lbEdit(id, key, removing: false)
                if result.code != 0 { anyBlocked = true }
                report.append(result.code == 0 ? "\(key): published" : "\(key): blocked (\(result.out))")
            }
            lbWriteStatus(report.sorted())
            interval = !anyBlocked && wanted == lastWanted && published == lastPublished ? min(60, interval * 2) : 10
            lastWanted = wanted; lastPublished = published
        } else {
            interval = 10
            // An unavailable API is never interpreted as an empty service list.
            lbWriteStatus(["discovery pending: \(services.out)"])
        }
        // Sleep in slices so a stop request is seen well inside the 45 s the stop/delete commands allow.
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            if stopping() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
