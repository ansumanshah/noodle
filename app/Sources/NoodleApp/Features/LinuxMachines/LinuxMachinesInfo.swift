import Foundation
import NoodleCore

/// What `noodle machine status NAME` reports beyond `machine list --json`: the guest address,
/// the shared folder and the disk space in use. Parsed from the command's fixed `key: value` lines.
struct LinuxMachineInfo: Equatable, Sendable {
    var address: String?
    var sharedFolder: String?
    var diskUsed: String?

    static func parse(_ text: String) -> LinuxMachineInfo {
        var info = LinuxMachineInfo()
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "address":
                if !value.isEmpty, !value.contains(" ") { info.address = value }
            case "share":
                if value != "none", !value.isEmpty {
                    info.sharedFolder = value.hasSuffix(" at /mnt/share") ? String(value.dropLast(" at /mnt/share".count)) : value
                }
            case "resources":
                if let open = value.range(of: "(", options: .backwards), let end = value.range(of: " used)") {
                    info.diskUsed = String(value[open.upperBound..<end.lowerBound])
                }
            default: break
            }
        }
        return info
    }
}

extension LinuxMachine {
    /// The real command that opens this machine. Noodle machines have no SSH server, so this is the way in.
    @MainActor var shellCommand: String { shellCommand(root: AppEnvironment.shared.paths.root) }

    func shellCommand(root: URL) -> String {
        let command = "noodle machine shell \(name)"
        let defaultRoot = NoodlePaths.resolve(environment: [:]).root
        guard root.standardizedFileURL.path != defaultRoot.standardizedFileURL.path else { return command }
        let quoted = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "NOODLE_HOME=\(quoted) \(command)"
    }

    /// "Ubuntu 24.04" for the official images, the bare image reference for custom ones.
    var subtitle: String {
        let reference = image.split(separator: "@").first.map(String.init) ?? image
        guard distro == "ubuntu" || distro == "alpine" else { return reference }
        return reference.replacingOccurrences(of: ":", with: " ").capitalized
    }

    var memoryText: String { Self.size(mebibytes: memoryMiB) }
    var diskText: String { "\(diskGiB) GiB" }

    static func size(mebibytes: Int) -> String {
        guard mebibytes >= 1024 else { return "\(mebibytes) MiB" }
        let gib = Double(mebibytes) / 1024
        return gib == gib.rounded() ? "\(Int(gib)) GiB" : String(format: "%.1f GiB", gib)
    }
}
