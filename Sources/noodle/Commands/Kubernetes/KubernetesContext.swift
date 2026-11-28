import Foundation
import NoodleCore

func k8sKubeconfig() {
    let kc = K8s.kubeconfig(paths)
    guard FileManager.default.fileExists(atPath: kc.path) else { die("no kubeconfig yet. Run `noodle kubernetes start` first.", code: 3) }
    out(kc.path)
}

/// Adds or removes Noodle's own cluster, user and context in a kubeconfig, through kubectl's own `config` verbs,
/// after a timestamped backup. Entries of other clusters are never read for rewriting, only passed through by kubectl.
func k8sUseContext(_ args: [String]) {
    var remove = false
    var target = env["NOODLE_KUBECONFIG_TARGET"] ?? (home as NSString).appendingPathComponent(".kube/config")
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--remove": remove = true
        case "--kubeconfig": i += 1; guard i < args.count else { die("missing path for --kubeconfig", code: 2) }; target = (args[i] as NSString).expandingTildeInPath
        default: die("unknown option \(args[i])", code: 2)
        }
        i += 1
    }
    guard let kubectl = which("kubectl") else { die("kubectl not found on PATH; use-context edits the file through kubectl.", code: 127) }
    let fm = FileManager.default
    func kc(_ a: [String]) -> (code: Int32, out: String) { run(kubectl, ["--kubeconfig", target] + a, extraEnv: ["KUBECONFIG": target]) }
    if fm.fileExists(atPath: target) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        var backup = target + ".noodle-backup-" + f.string(from: Date())
        var n = 1
        while fm.fileExists(atPath: backup) { n += 1; backup = target + ".noodle-backup-" + f.string(from: Date()) + "-\(n)" }
        do { try fm.copyItem(atPath: target, toPath: backup) } catch { die("cannot back up \(target): \(error.localizedDescription)") }
        out("Backed up \(target) to \(backup)")
    } else if remove { out("No kubeconfig at \(target); nothing to remove."); return }
    let name = K8s.contextName
    if remove {
        let current = kc(["config", "current-context"]).out
        for sub in ["delete-context", "delete-cluster", "delete-user"] { _ = kc(["config", sub, name]) }
        if current == name { _ = kc(["config", "unset", "current-context"]) }
        out("Removed the \(name) context, cluster and user from \(target).")
        return
    }
    let ours = K8s.kubeconfig(paths)
    guard let text = try? String(contentsOf: ours, encoding: .utf8) else { die("no Noodle kubeconfig yet. Run `noodle kubernetes start` first.", code: 3) }
    guard let server = K8s.value(of: "server", in: text), let ca = K8s.value(of: "certificate-authority-data", in: text),
          let cert = K8s.value(of: "client-certificate-data", in: text), let key = K8s.value(of: "client-key-data", in: text) else {
        die("the Noodle kubeconfig is missing certificate data; run `noodle kubernetes start`", code: 1)
    }
    // Not the daemon's tmpDir: starting the daemon wipes it. die() exits without running defers, so remove first.
    let tmp = fm.temporaryDirectory.appendingPathComponent("noodle-k8s-ctx-" + UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: tmp) }
    func fail(_ message: String) -> Never { try? fm.removeItem(at: tmp); die(message) }
    var files: [String: String] = [:]
    for (label, b64) in [("ca", ca), ("cert", cert), ("key", key)] {
        guard let d = Data(base64Encoded: b64) else { fail("bad certificate data in the Noodle kubeconfig") }
        let p = tmp.appendingPathComponent(label).path
        _ = fm.createFile(atPath: p, contents: d, attributes: [.posixPermissions: 0o600]); files[label] = p
    }
    try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let steps: [[String]] = [
        ["config", "set-cluster", name, "--server=" + server, "--certificate-authority=" + files["ca"]!, "--embed-certs=true"],
        ["config", "set-credentials", name, "--client-certificate=" + files["cert"]!, "--client-key=" + files["key"]!, "--embed-certs=true"],
        ["config", "set-context", name, "--cluster=" + name, "--user=" + name],
        ["config", "use-context", name],
    ]
    for s in steps { let r = kc(s); if r.code != 0 { fail("kubectl \(s[1]) failed: \(r.out)") } }
    out("Added the \(name) context to \(target) and made it current. Undo with `noodle kubernetes use-context --remove`.")
}
