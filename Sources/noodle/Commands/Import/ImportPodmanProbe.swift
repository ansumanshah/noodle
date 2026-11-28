import Foundation
import NoodleCore

/// The running Podman machine's Docker-compatible socket. Asks `podman` when it is on PATH (list, then inspect that
/// machine by name), else probes the default folders. Only called when the user names `podman` as the source.
func podmanSocket(env: [String: String], cancellation: ImportCancellation, timeout: TimeInterval = 10) -> String? {
    var output: String?
    let search = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":") + ["/opt/homebrew/bin", "/usr/local/bin"]
    if let bin = search.map({ "\($0)/podman" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
       let list = runBounded(bin, ["machine", "list", "--format", "json"], timeout: timeout, cancelled: { cancellation.isCancelled }),
       let name = ImportNaming.runningPodmanMachine(listJSON: Data(list.utf8)) {
        output = runBounded(bin, ["machine", "inspect", name, "--format", "{{.ConnectionInfo.PodmanSocket.Path}}"],
                            timeout: timeout, cancelled: { cancellation.isCancelled })
    }
    return ImportNaming.podmanSocket(inspectOutput: output, home: env["HOME"] ?? NSHomeDirectory(), tmpDir: env["TMPDIR"],
                                     exists: { FileManager.default.fileExists(atPath: $0) })
}
