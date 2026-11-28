import Foundation
import NoodleCore

private let shareUsage = "usage: noodle share list | add <absolute-folder> | remove <absolute-folder> [--restart]"

func cmdShare(_ args: [String]) {
    var settings = VMSettings.load(paths: paths)
    var args = args
    let restart = args.first == "remove" && args.dropFirst().contains("--restart")
    if restart { args.removeAll { $0 == "--restart" } }
    switch args.first {
    case "list" where args.count == 1:
        for path in settings.approvedDirectories { out(path) }
    case "add", "remove":
        guard args.count == 2 else { usageDie(shareUsage) }
        let path: String
        if args[0] == "add" {
            do { path = try VMSettings.canonicalDirectory(args[1]) }
            catch { usageDie("choose an existing absolute directory: \(args[1])") }
        } else {
            guard args[1].hasPrefix("/") else { usageDie("folder path must be absolute") }
            path = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath().path
        }
        if args[0] == "add" {
            if !settings.approvedDirectories.contains(path) { settings.approvedDirectories.append(path) }
        } else {
            settings.approvedDirectories.removeAll { $0 == path }
        }
        do { try settings.save(paths: paths) } catch { die("cannot save shared folders: \(error.localizedDescription)") }
        let kubernetes = settings.workloadSharedFolders == true
        if args[0] == "add" {
            out("Approved \(path). Single-file binds from this folder can now run; containers that bind such a file can read its sibling files. Directory binds never need approval.")
            if kubernetes {
                out("Privileged containers see this at their next start. Run `noodle kubernetes start` to give the cluster the new folder list (it recreates the node; data is kept).")
            }
            return
        }
        out("Removed \(path). Stop affected containers to revoke existing shares.")
        guard kubernetes else { return }
        if restart { k8sRevokeRemovedFolder(); return }
        note("The privileged containers VM and the Kubernetes node keep access to \(path) until they restart. To end it now, run: noodle share remove \"\(path)\" --restart (stops containers in that VM and recreates the node; data is kept).")
    default: usageDie(shareUsage)
    }
}
