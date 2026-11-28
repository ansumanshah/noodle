import Foundation
import NoodleCore

func k8sStop() {
    k8sStopLoadBalancerWatcher()
    guard ping() else { out("Kubernetes is stopped (the Noodle engine is not running)."); return }
    let info = inspectCluster()
    guard info.exists else { out("Kubernetes has not been created. Nothing to stop."); return }
    requireManaged(info)
    guard info.running else { out("Kubernetes is already stopped."); return }
    let r = dk(["stop", "--time", "30", K8s.container], timeout: 90)
    guard r.code == 0 else { die("cannot stop the cluster: \(r.out)") }
    out("Kubernetes stopped. The data is kept; `noodle kubernetes start` resumes it.")
}
func k8sDelete(_ args: [String]) {
    let yes = hasYes(args)
    if let bad = args.first(where: { !yesFlags.contains($0) }) { usageDie("unknown option \(bad)") }
    let dir = K8s.directory(paths)
    let fm = FileManager.default
    var info = ClusterInfo()
    var volumeExists = false
    let engineUp = ping()
    if !engineUp, fm.fileExists(atPath: dir.path) {
        die("the Noodle engine is not running; start it with `noodle start` so the cluster can be removed", code: ExitCode.engineDown)
    }
    if engineUp {
        info = inspectCluster()
        volumeExists = dk(["volume", "inspect", K8s.volume], timeout: 20).code == 0
        requireManaged(info)
    }
    guard info.exists || volumeExists || fm.fileExists(atPath: dir.path) else { out("No Kubernetes cluster to delete."); return }
    if !yes {
        guard isatty(STDIN_FILENO) != 0 else { usageDie("refusing to delete without --yes when input is not a terminal") }
        FileHandle.standardError.write(Data("Delete the Kubernetes cluster and all of its data (containers, volumes, images, kubeconfig)? [y/N] ".utf8))
        guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { note("Cancelled."); exit(ExitCode.failure) }
    }
    k8sStopLoadBalancerWatcher()
    if ping() {
        if info.exists, dk(["rm", "-f", "-v", K8s.container], timeout: 90).code != 0 { die("cannot remove the cluster container") }
        if volumeExists, dk(["volume", "rm", "-f", K8s.volume], timeout: 60).code != 0 { die("cannot remove the cluster data volume") }
        _ = dk(["network", "rm", K8s.network], timeout: 30)
    } else if info.exists || volumeExists {
        die("the Noodle engine is not running; start it with `noodle start` so the cluster can be removed", code: 3)
    }
    try? fm.removeItem(at: dir)
    out("Kubernetes deleted. Nothing is left on disk. \(fm.fileExists(atPath: (home as NSString).appendingPathComponent(".kube/config")) ? "Your ~/.kube/config is untouched; `noodle kubernetes use-context --remove` removes an entry you added earlier." : "")".trimmingCharacters(in: .whitespaces))
}
