import Foundation
import NoodleCore

// `noodle logs` and `noodle diagnostics`. Local only: no upload, no crash reporting.
// A future opt-in upload would need a consent prompt that names every file in the archive.

func cmdLogs(_ args: [String], paths: NoodlePaths) {
    guard LogsRouting.route(args) == .component else {
        die("usage: noodle logs [engine|linux|privileged] [-n N|--tail N] [--grep text] [-f|--follow] [--raw]\nFor container logs, use docker --context noodle logs CONTAINER.", code: 2)
    }
    var component: LogComponent?
    var count = 100, filter: String?, follow = false, raw = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-n", "--tail":
            i += 1
            guard i < args.count, let n = Int(args[i]), n >= 0 else { usageDie("usage: noodle logs [engine|linux|privileged] [-n lines|--tail lines] [--grep text] [-f|--follow] [--raw]") }
            count = n
        case "--grep":
            i += 1
            guard i < args.count else { usageDie("--grep needs text") }
            filter = args[i]
        case "-f", "--follow": follow = true
        case "--raw": raw = true
        default:
            guard component == nil, let c = LogComponent(rawValue: a) else { usageDie("unknown log or option '\(a)'. Logs: \(LogComponent.allCases.map(\.rawValue).joined(separator: ", "))") }
            component = c
        }
        i += 1
    }
    if follow && component == nil { usageDie("--follow needs one log: engine, linux or privileged") }
    let redactor = Redactor()
    let show: (String) -> String = { raw ? $0 : redactor.redact($0) }
    let components = component.map { [$0] } ?? LogComponent.allCases
    for c in components {
        let url = c.file(in: paths)
        let lines = DiagnosticLogs.tail(url, count: count, filter: filter)
        if components.count > 1 || lines.isEmpty { out("==> \(c.rawValue) (\(show(url.path))) <==") }
        for l in lines { out(show(l)) }
    }
    guard follow else { return }
    guard let c = component else { return }
    var offset = (try? FileManager.default.attributesOfItem(atPath: c.file(in: paths).path)[.size] as? UInt64) ?? 0
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        guard let h = try? FileHandle(forReadingFrom: c.file(in: paths)), let end = try? h.seekToEnd() else { continue }
        defer { try? h.close() }
        if end < offset { offset = 0 }   // rotated or truncated
        guard end > offset else { continue }
        try? h.seek(toOffset: offset)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        offset = end
        for l in text.split(separator: "\n") where filter.map({ l.localizedCaseInsensitiveContains($0) }) ?? true { out(show(String(l))) }
    }
}

func cmdDiagnostics(_ args: [String], paths: NoodlePaths, version: String) {
    var dest: URL?
    var list = false
    var json = false
    var i = 0
    while i < args.count {
        if args[i] == "-o" || args[i] == "--output" {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { usageDie("usage: noodle diagnostics [--list] [-o|--output file.tar.gz] [--json]") }
            dest = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath); i += 2
        }
        else if args[i] == "--list" { list = true; i += 1 }
        else if args[i] == "--json" { json = true; i += 1 }
        else { usageDie("usage: noodle diagnostics [--list] [-o|--output file.tar.gz] [--json]") }
    }
    let entries = DiagnosticsBundle.inventory(paths: paths)
    if list && json { jsonOut(diagnosticsListJSON(entries.map { ($0.name, $0.source?.path) })); return }
    if list {
        for entry in entries { out("\(entry.name) <- \(entry.source?.path ?? "generated locally")") }
        return
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let target = dest ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("noodle-diagnostics-\(stamp).tar.gz")
    do {
        try DiagnosticsBundle.write(paths: paths, to: target, version: version, entries: entries)
        if json { jsonOut(diagnosticsJSON(path: target.path, entries: entries.map(\.name))) } else { out("wrote \(target.path)") }
        (json ? err : out)("Scrubbed on this Mac: secrets and personal paths are removed; image, container, project and host identities are anonymized. Nothing was sent. Read it before you share it.")
    } catch { die("could not write diagnostics: \(error)") }
}
