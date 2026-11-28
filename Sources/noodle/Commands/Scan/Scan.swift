import Foundation
import NoodleCore

private let scanUsage = "usage: noodle scan IMAGE [--json] [--fail-on SEVERITY] | scan --history [IMAGE] | scan --clear-cache | sbom IMAGE [--output FILE]"
private let scanSeverities = ["negligible", "low", "medium", "high", "critical"]

private struct ScanOptions {
    var image: String?
    var json = false
    var history = false
    var clearCache = false
    var failOn: String?
    var output: String?

    init(_ args: [String], sbom: Bool) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json" where !sbom: json = true
            case "--history" where !sbom: history = true
            case "--clear-cache" where !sbom: clearCache = true
            case "--fail-on" where !sbom, "--output" where sbom:
                i += 1
                guard i < args.count, !args[i].hasPrefix("--") else { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
                if arg == "--output" { output = args[i] }
                else {
                    let severity = args[i].lowercased()
                    guard scanSeverities.contains(severity) else { throw CLIError("invalid severity: \(args[i]); use \(scanSeverities.joined(separator: ", "))", exitCode: ExitCode.usage) }
                    failOn = severity
                }
            default:
                guard !arg.hasPrefix("-"), !arg.isEmpty, image == nil else { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
                image = arg
            }
            i += 1
        }
        if clearCache {
            guard !history, image == nil, !json, failOn == nil else { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
        } else if history {
            guard failOn == nil else { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
        } else if image == nil { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
    }
}

func cmdScan(_ args: [String], sbom: Bool) {
    do {
        let code = try performScan(ScanOptions(args, sbom: sbom), sbom: sbom)
        // All scratch files and handles have been cleaned before exiting.
        if code != 0 { exit(code) }
    } catch { die(error) }
}

private func performScan(_ options: ScanOptions, sbom: Bool) throws -> Int32 {
    let fm = FileManager.default
    let history = paths.root.appendingPathComponent("scans/history")
    if options.clearCache {
        let cache = paths.root.appendingPathComponent("cache/scans")
        if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
        out("Scan cache cleared")
        return 0
    }
    if options.history {
        let files = try scanHistoryFiles(history)
        var entries: [[String: Any]] = []
        for file in files {
            guard let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw CLIError("invalid scan history: \(file.lastPathComponent)")
            }
            if let image = options.image, entry["image"] as? String != image, entry["imageID"] as? String != image { continue }
            entries.append(entry)
        }
        out(jsonLine(entries))
        return 0
    }
    guard let image = options.image else { throw CLIError(scanUsage, exitCode: ExitCode.usage) }
    scanSweepStale(in: paths.tmpDir, prefix: "scan-")
    let work = paths.tmpDir.appendingPathComponent("scan-" + UUID().uuidString)
    try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: work) }
    let layout = work.appendingPathComponent("image")
    // Resolve/export before fetching any helper, so missing images cost nothing.
    let imageID = try scanExport(image, to: layout)
    let database = paths.root.appendingPathComponent("cache/scans/grype/db")
    if !sbom, !fm.fileExists(atPath: database.path) {
        let notice = "First scan: downloading the vulnerability database, about 3.2 GB on disk. This can take several minutes. "
            + "Remove it later with `noodle scan --clear-cache`.\n"
        FileHandle.standardError.write(Data(notice.utf8))
    }
    let pin = sbom ? ScanTool.syft : ScanTool.grype
    let binary = try pin.executable()
    let output = work.appendingPathComponent("result.json")
    let args = ["oci-dir:" + layout.path, "--output", sbom ? "cyclonedx-json" : "json"]
    let code = try scanProcess(binary, arguments: args, work: work, output: output)
    guard code == 0 else { throw CLIError("\(pin.name) failed with exit code \(code)") }
    let data = try Data(contentsOf: output)
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError("invalid JSON from \(pin.name)") }
    if sbom {
        guard result["bomFormat"] as? String == "CycloneDX", result["components"] is [[String: Any]] else {
            throw CLIError("Syft did not produce a CycloneDX SBOM")
        }
        if let name = options.output { try data.write(to: URL(fileURLWithPath: name), options: .atomic) }
        else { FileHandle.standardOutput.write(data); out("") }
        return 0
    }
    guard let matches = result["matches"] as? [[String: Any]] else { throw CLIError("Grype result has no matches") }
    try saveScanHistory(["image": image, "imageID": imageID, "created": ISO8601DateFormatter().string(from: Date()),
                         "scanner": pin.name, "version": pin.version, "result": result], in: history)
    if options.json { FileHandle.standardOutput.write(data); out("") }
    else {
        out("IMAGE \(image) (\(imageID))")
        out("PACKAGE\tVERSION\tVULNERABILITY\tSEVERITY\tFIX")
        for match in matches {
            let artifact = match["artifact"] as? [String: Any] ?? [:]
            let vulnerability = match["vulnerability"] as? [String: Any] ?? [:]
            let fix = vulnerability["fix"] as? [String: Any] ?? [:]
            out([artifact["name"] as? String ?? "?", artifact["version"] as? String ?? "?",
                 vulnerability["id"] as? String ?? "?", vulnerability["severity"] as? String ?? "Unknown",
                 (fix["versions"] as? [String] ?? []).joined(separator: ", ")].joined(separator: "\t"))
        }
        out("\(matches.count) vulnerabilities")
    }
    if let threshold = options.failOn, let rank = scanSeverities.firstIndex(of: threshold) {
        for match in matches {
            let vulnerability = match["vulnerability"] as? [String: Any] ?? [:]
            let severity = (vulnerability["severity"] as? String ?? "").lowercased()
            if let found = scanSeverities.firstIndex(of: severity), found >= rank { return 2 }
        }
    }
    return 0
}

private func scanHistoryFiles(_ directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func saveScanHistory(_ entry: [String: Any], in directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Lock only publication/pruning so parallel scans retain at most 50 results.
    let lock = directory.deletingLastPathComponent().appendingPathComponent("history.lock")
    let fd = open(lock.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard fd >= 0 else { throw CLIError("cannot lock scan history") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw CLIError("cannot lock scan history") }
    defer { _ = flock(fd, LOCK_UN) }
    let name = String(format: "%020.0f", Date().timeIntervalSince1970 * 1_000_000) + "-" + UUID().uuidString + ".json"
    let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    let files = try scanHistoryFiles(directory)
    for file in files.prefix(max(0, files.count - 50)) { try fm.removeItem(at: file) }
}
