import Foundation

/// The component logs `noodle logs` can show. Files only: nothing runs when this is unused.
public enum LogComponent: String, CaseIterable, Sendable {
    case engine, linux, privileged

    public func file(in paths: NoodlePaths) -> URL {
        switch self {
        case .engine: paths.root.appendingPathComponent("noodled.log")
        case .linux: paths.vmLog
        case .privileged: paths.workloadVMLog
        }
    }
}

public enum DiagnosticLogs {
    /// The last `count` lines of a file that contain `filter` (case-insensitive), reading at most `maxBytes` from the end.
    public static func tail(_ url: URL, count: Int, filter: String? = nil, maxBytes: Int = 4_194_304) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // first line is cut mid-way
        if let filter, !filter.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(filter) } }
        return Array(lines.suffix(max(0, count)))
    }

    /// A scrubbed local archive (`.tar.gz`) for a bug report. Nothing is sent anywhere.
    /// Contents: `info.txt`, `settings.json`, and the last `lines` of each component log, all through `Redactor`.
    public static func writeArchive(paths: NoodlePaths, to destination: URL, lines: Int = 2000,
                                    redactor: Redactor = Redactor(), version: String) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("noodle-diag-\(UUID().uuidString)", isDirectory: true)
        let name = destination.lastPathComponent.replacingOccurrences(of: ".tar.gz", with: "")
        let dir = stage.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }

        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var info = ["noodle: \(version)", "macOS: \(os)", "arch: \(machine())", "memory_mib: \(ProcessInfo.processInfo.physicalMemory / 1_048_576)",
                    "generated: \(ISO8601DateFormatter().string(from: Date()))", "data: \(paths.root.path)"]
        for c in LogComponent.allCases {
            let f = c.file(in: paths)
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int) ?? nil
            info.append("log.\(c.rawValue): " + (size.map { "\($0) bytes" } ?? "absent"))
        }
        try write(redactor.redact(info.joined(separator: "\n")) + "\n", to: dir.appendingPathComponent("info.txt"))
        if let settings = try? String(contentsOf: paths.settingsFile, encoding: .utf8) {
            try write(redactor.redact(settings), to: dir.appendingPathComponent("settings.json"))
        }
        for c in LogComponent.allCases {
            let l = tail(c.file(in: paths), count: lines)
            guard !l.isEmpty else { continue }
            try write(redactor.redact(l.joined(separator: "\n")) + "\n", to: dir.appendingPathComponent("\(c.rawValue).log"))
        }
        try? fm.removeItem(at: destination)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", destination.path, "-C", stage.path, name]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func write(_ s: String, to url: URL) throws {
        try Data(s.utf8).write(to: url, options: .atomic)
    }

    private static func machine() -> String {
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
