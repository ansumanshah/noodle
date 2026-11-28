import Foundation
import NoodleCore

// Local catalog clients. These commands never connect to the socket or start the daemon.
func cmdBuildCatalog(_ args: [String], paths: NoodlePaths) {
    if args.first == "image" {
        guard args.dropFirst().first == "layers" else {
            die("usage: noodle image layers IMAGE [--json]\nFor other image commands, use docker --context noodle image.", code: 2)
        }
        cmdImageLayers(Array(args.dropFirst(2)), paths: paths)
        return
    }
    let usage = "usage: noodle builds list [--json] | inspect ID | logs ID | rm ID|--all"
    let command = Array(args.dropFirst())
    do {
        guard let action = command.first else { usageDie(usage) }
        switch action {
        case "list": guard command.count == 1 || command == ["list", "--json"] else { usageDie(usage) }
        case "inspect", "logs", "rm":
            guard command.count == 2, !command[1].hasPrefix("-") || (action == "rm" && command[1] == "--all") else { usageDie(usage) }
        default: usageDie(usage)
        }
        let directory = paths.root.appendingPathComponent("builds", isDirectory: true)
        // Lock only an existing store. Reading a fresh home creates nothing.
        let lockPath = directory.appendingPathComponent(".lock").path
        let fd = open(lockPath, O_RDONLY | O_CLOEXEC)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 {
            guard flock(fd, action == "rm" ? LOCK_EX : LOCK_SH) == 0 else { throw POSIXError(.EIO) }
        } else if FileManager.default.fileExists(atPath: directory.path) {
            throw POSIXError(.EIO)
        }
        let files = FileManager.default.fileExists(atPath: directory.path)
            ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            : []
        let records: [(URL, [String: Any])] = try files.map { file in
            guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  record["id"] as? String == file.deletingPathExtension().lastPathComponent else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if !["inspect", "logs"].contains(action) || command.last != record["id"] as? String {
                record.removeValue(forKey: "log")
            }
            return (file, record)
        }.sorted {
            let a = $0.1["startedAt"] as? String ?? "", b = $1.1["startedAt"] as? String ?? ""
            return a == b ? $0.0.lastPathComponent > $1.0.lastPathComponent : a > b
        }
        switch action {
        case "list":
            if command.contains("--json") {
                try printBuildJSON(records.map { var r = $0.1; r.removeValue(forKey: "log"); return r })
            } else {
                out("ID\tSTATUS\tSECONDS\tCACHED/TOTAL\tTAGS")
                for (_, r) in records {
                    out("\(r["id"] ?? "")\t\(r["status"] ?? "")\t\(r["duration"] ?? 0)\t\(r["cachedSteps"] ?? 0)/\(r["totalSteps"] ?? 0)\t\((r["tags"] as? [String] ?? []).joined(separator: ", "))")
                }
            }
        case "inspect", "logs", "rm":
            let id = command[1]
            if action == "rm", id == "--all" {
                for (file, _) in records { try FileManager.default.removeItem(at: file) }
                return
            }
            // Match exact record identifiers. User input never becomes a filesystem path.
            guard let (file, r) = records.first(where: { $0.1["id"] as? String == id }) else { die("build not found: \(id)") }
            if action == "inspect" { try printBuildJSON(r) }
            else if action == "logs" { FileHandle.standardOutput.write(Data((r["log"] as? String ?? "").utf8)) }
            else { try FileManager.default.removeItem(at: file) }
        default: usageDie(usage)
        }
    } catch { die("build history: \(error.localizedDescription)") }
}

private func printBuildJSON(_ value: Any) throws {
    out(jsonLine(value, pretty: true))
}

// Decode just the fields this view needs, preserving the local catalog's size convention.
private struct LayerCatalogImage: Decodable {
    struct Layer: Decodable {
        var digest: String
        var size: Int64
        var unpackedBytes: Int64?
        var bytes: Int64 { unpackedBytes ?? size }
    }
    struct Config: Decodable {
        struct Entry: Decodable {
            var created_by: String?
            var empty_layer: Bool?
        }
        var history: [Entry]?
    }
    var id: String
    var repoTags: [String]
    var repoDigests: [String]
    var layers: [Layer]
    var config: Config
}

private func cmdImageLayers(_ args: [String], paths: NoodlePaths) {
    let args = args.count == 2 && args[0] == "--json" ? [args[1], "--json"] : args
    guard args.count == 1 || (args.count == 2 && args[1] == "--json"),
          let name = args.first, !name.hasPrefix("-") else { usageDie("usage: noodle image layers IMAGE [--json]") }
    do {
        let catalog = try JSONDecoder().decode([String: LayerCatalogImage].self, from: Data(contentsOf: paths.imagesFile))
        func familiar(_ value: String) -> String {
            var ref = value
            for prefix in ["docker.io/", "index.docker.io/"] where ref.hasPrefix(prefix) { ref = String(ref.dropFirst(prefix.count)) }
            if ref.hasPrefix("library/") { ref = String(ref.dropFirst(8)) }
            if !ref.contains("@"), !(ref.split(separator: "/").last?.contains(":") ?? false) { ref += ":latest" }
            return ref
        }
        let reference = familiar(name)
        let hex = name.hasPrefix("sha256:") ? String(name.dropFirst(7)) : name
        let isID = !hex.isEmpty && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        let matches = catalog.values.filter { image in
            image.repoTags.contains { familiar($0) == reference }
                || image.repoDigests.contains { familiar($0) == reference }
                || (isID && image.id.dropFirst(7).hasPrefix(hex))
        }
        guard matches.count == 1, let image = matches.first else {
            die(matches.isEmpty ? "image not found: \(name)" : "image reference is ambiguous: \(name)")
        }
        var instructions = [String](repeating: "", count: image.layers.count)
        var index = image.layers.count - 1
        for entry in (image.config.history ?? []).reversed() where entry.empty_layer != true {
            guard index >= 0 else { break }
            instructions[index] = entry.created_by ?? ""
            index -= 1
        }
        let total = image.layers.reduce(Int64(0)) { $0 + $1.bytes }
        let rows: [[String: Any]] = image.layers.enumerated().map { i, layer in
            ["digest": layer.digest, "size": layer.bytes, "instruction": instructions[i],
             "share": total > 0 ? Double(layer.bytes) / Double(total) * 100 : 0]
        }
        if args.contains("--json") { try printBuildJSON(rows) }
        else {
            out("DIGEST\tBYTES\tPERCENT\tINSTRUCTION")
            for row in rows {
                out("\(row["digest"] ?? "")\t\(row["size"] ?? 0)\t\(String(format: "%.2f", row["share"] as? Double ?? 0))\t\(row["instruction"] ?? "")")
            }
        }
    } catch { die("image layers: \(error.localizedDescription)") }
}
