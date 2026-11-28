import Foundation
import NoodleCore

/// Local, on-demand collection. Inventory is shared by preview and archive creation.
enum DiagnosticsBundle {
    struct Entry {
        let name: String
        let source: URL?
    }

    static func inventory(paths: NoodlePaths, crashDirectories: [URL]? = nil) -> [Entry] {
        let fm = FileManager.default
        var result = [Entry(name: "info.txt", source: nil)]
        let candidates = [Entry(name: "settings.json", source: paths.settingsFile)] + LogComponent.allCases.map {
            Entry(name: "\($0.rawValue).log", source: $0.file(in: paths))
        }
        result += candidates.filter { entry in
            guard let source = entry.source,
                  let attributes = try? fm.attributesOfItem(atPath: source.path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
        }
        let directories = crashDirectories ?? [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
            paths.root.appendingPathComponent("crashes"),
        ]
        var index = 0
        for directory in directories {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent.lowercased()
                guard ["noodle", "noodled", "noodle-machine"].contains(where: { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") || name.hasPrefix($0 + ".") }),
                      ["ips", "crash"].contains(file.pathExtension),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                index += 1
                // Never put a source filename containing a user or host into the archive.
                result.append(Entry(name: "crash-\(index).\(file.pathExtension)", source: file))
            }
        }
        return result
    }

    static func identities(paths: NoodlePaths) -> [String] {
        var result: [String] = []
        let keys: Set<String> = ["name", "image", "hostname", "repotags", "repodigests", "com.docker.compose.project", "username", "email", "serveraddress"]
        func visit(_ value: Any, key: String = "") {
            if let text = value as? String, keys.contains(key.lowercased()) {
                result.append(text)
                if key.lowercased() == "name", text.hasPrefix("/") { result.append(String(text.dropFirst())) }
                // Also cover repository names logged without their tag or digest.
                if key.lowercased() == "repotags" || key.lowercased() == "image" {
                    if let colon = text.lastIndex(of: ":"), !text[colon...].contains("/") { result.append(String(text[..<colon])) }
                }
            } else if let object = value as? [String: Any] {
                for (name, child) in object { visit(child, key: name) }
            } else if let array = value as? [Any] {
                for child in array { visit(child, key: key) }
            }
        }
        // These files supply identity hints only; their raw contents never enter the bundle.
        for file in [paths.stateFile, paths.imagesFile, paths.settingsFile] {
            if let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) { visit(json) }
        }
        return result
    }

    static func write(paths: NoodlePaths, to destination: URL, version: String, entries: [Entry]) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("noodle-diag-\(UUID().uuidString)")
        let name = destination.lastPathComponent.replacingOccurrences(of: ".tar.gz", with: "")
        guard !name.isEmpty, name != ".", name != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        let directory = stage.appendingPathComponent(name)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let redactor = Redactor(identities: identities(paths: paths), anonymizeIdentities: true)
        for entry in entries {
            let text: String
            if let source = entry.source {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                // Fail closed rather than truncate in the middle of a PEM block or a credential.
                let limit = 16 * 1024 * 1024
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                if data.count > limit { text = "[omitted: source exceeds diagnostics size limit]\n" }
                else {
                    let scrubbed = redactor.redact(String(decoding: data, as: UTF8.self))
                    if entry.name.hasSuffix(".log") {
                        text = scrubbed.split(separator: "\n", omittingEmptySubsequences: true).suffix(2000).joined(separator: "\n") + "\n"
                    } else { text = scrubbed }
                }
            } else {
                text = redactor.redact("noodle: \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nmemory_mib: \(ProcessInfo.processInfo.physicalMemory / 1_048_576)\ndata: \(paths.root.path)\n")
            }
            try Data(text.utf8).write(to: directory.appendingPathComponent(entry.name), options: .atomic)
        }
        let archive = stage.appendingPathComponent("archive.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", stage.path, "--", name]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // Copy only the completed, private archive to the destination.
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: archive, to: destination)
    }
}
