import Foundation
import NoodleCore

func setupUninstall(_ args: [String]) {
    let allowed = yesFlags.union(["--delete-data"])
    guard args.allSatisfy(allowed.contains) else { die("usage: noodle uninstall [--delete-data --yes]", code: 2) }
    let deleteData = args.contains("--delete-data")
    // Validate consent before changing any installation state.
    if deleteData && !hasYes(args) {
        guard isatty(STDIN_FILENO) != 0 else { usageDie("data deletion requires explicit confirmation: noodle uninstall --delete-data --yes") }
        out("Type delete to permanently remove \(paths.root.path):")
        guard readLine() == "delete" else { die("data deletion cancelled") }
    }
    do {
        let installLock = try ToolInstallLock(paths: paths)
        defer { withExtendedLifetime(installLock) {} }
        if deleteData { try setupVerifyDataDeletion() }
        let machineLocks = try setupLockStoppedMachines()
        defer { for fd in machineLocks { close(fd) } }
        let receipt = setupReceipt()
        try setupCleanProfiles(receipt)
        try stopModelRunnerIfPresent()
        try setupRemoveAgent(label: agentLabel)
        try setupRemoveAgent(label: setupLegacyLabel)
        runnersRemoveAgent()
        if ping() { cmdStop() }
        try setupRemoveContext()
        unlinkPlugins()
        let stubs = LazyToolPlugin.directory(paths)
        if setupFM.fileExists(atPath: stubs.path) { try setupFM.removeItem(at: stubs) }
        for (key, _) in receipt {
            if key.hasPrefix("link:") {
                let link = URL(fileURLWithPath: String(key.dropFirst(5)))
                if setupOwnedLink(link) { try setupFM.removeItem(at: link) }
            }
        }
        let cli = setupBin.appendingPathComponent("noodle")
        if let hash = receipt["cli-sha256"], (try? Digest.sha256(file: cli)) == hash { try setupFM.removeItem(at: cli) }
        let fallbackCLI = paths.root.appendingPathComponent("bin/noodle")
        if let hash = receipt["fallback-cli-sha256"], (try? Digest.sha256(file: fallbackCLI)) == hash { try setupFM.removeItem(at: fallbackCLI) }
        if setupFM.fileExists(atPath: socketPath) {
            let attrs = try setupFM.attributesOfItem(atPath: socketPath)
            if attrs[.type] as? FileAttributeType == .typeSocket { try setupFM.removeItem(atPath: socketPath) }
        }
        if deleteData {
            if setupFM.fileExists(atPath: paths.root.path) { try setupFM.removeItem(at: paths.root) }
            out("Deleted data in \(paths.root.path)")
        }
        else {
            if setupFM.fileExists(atPath: setupReceiptURL.path) { try setupFM.removeItem(at: setupReceiptURL) }
            out("Kept data in \(paths.root.path). Delete only with `noodle uninstall --delete-data --yes`.")
        }
    } catch { die(error.localizedDescription) }
}
