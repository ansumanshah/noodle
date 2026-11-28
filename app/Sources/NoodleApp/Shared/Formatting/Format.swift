import Foundation

enum Fmt {
    /// "1 model", "3 models": the count and its noun, plural unless exactly one.
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
    nonisolated(unsafe) private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()
    static func ago(_ unix: Int) -> String {
        unix <= 0 ? "—" : rel.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: .now)
    }
    static func percent(_ v: Double) -> String { String(format: "%.1f%%", v) }
}
