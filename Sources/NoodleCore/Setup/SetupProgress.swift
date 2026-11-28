import Foundation

/// Progress and readouts for the setup sheet, derived from what is on disk or what a tool printed.
public enum SetupProgress {
    /// Fraction of the planned downloads present in the work folder, never 1 before the install ends.
    /// `files` maps a download file name to its current size; `expected` maps it to its final size.
    public static func downloadFraction(files: [String: Int64], expected: [String: Int64]) -> Double {
        let total = expected.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let have = expected.reduce(Int64(0)) { $0 + min(files[$1.key] ?? 0, $1.value) }
        return min(0.99, Double(have) / Double(total))
    }

    /// "412 ms" under a second, "1.3 s" under ten, then whole seconds.
    public static func duration(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1000
        return seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }
}

/// Reads `docker pull` lines (the non-terminal form) into a layer count.
public struct PullProgress: Sendable, Equatable {
    public private(set) var layers = Set<String>()
    public private(set) var finished = Set<String>()
    public private(set) var complete = false
    public private(set) var latest = ""

    public init() {}

    public var fraction: Double? {
        complete ? 1 : layers.isEmpty ? nil : min(0.99, Double(finished.count) / Double(layers.count))
    }

    public mutating func ingest(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        latest = text
        if text.hasPrefix("Status:") { complete = true; return }
        if text.hasPrefix("Digest:") { return }
        guard let colon = text.firstIndex(of: ":") else { return }
        let id = String(text[..<colon])
        guard id.count >= 6, id.allSatisfy({ $0.isHexDigit }) else { return }
        let rest = text[text.index(after: colon)...].lowercased()
        if rest.contains("pulling fs layer") || rest.contains("waiting") || rest.contains("downloading") { layers.insert(id) }
        if rest.contains("pull complete") || rest.contains("already exists") { layers.insert(id); finished.insert(id) }
    }
}

/// What `noodle import <source> --list` printed, as counts.
public struct ImportInventory: Sendable, Equatable {
    public var images = 0, volumes = 0, containers = 0
    public init(images: Int = 0, volumes: Int = 0, containers: Int = 0) {
        self.images = images; self.volumes = volumes; self.containers = containers
    }
    public var isEmpty: Bool { images + volumes + containers == 0 }

    public static func parse(_ text: String) -> ImportInventory {
        func count(_ pattern: String) -> Int {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }
        return ImportInventory(images: count(#"images \((\d+) tagged"#), volumes: count(#"volumes \((\d+)\)"#),
                               containers: count(#"stopped containers \((\d+) of"#))
    }

    /// "3 images, 1 volume and 2 stopped containers", leaving out zeros.
    public var summary: String {
        let parts = [(images, "image", "images"), (volumes, "volume", "volumes"), (containers, "stopped container", "stopped containers")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        switch parts.count {
        case 0: return "nothing to copy"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
