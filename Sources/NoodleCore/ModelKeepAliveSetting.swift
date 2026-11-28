import Foundation

/// The keep-alive the user picked in Settings, kept in `<root>/models/keep-alive.json` so the CLI and app agree.
/// It is only the fallback: an explicit `--keep-alive` or `NOODLE_MODEL_KEEP_ALIVE` wins, and a running model
/// server keeps the value it started with until the next start (the runtime reads it at launch).
public enum ModelKeepAliveSetting {
    private struct Saved: Codable { let keepAlive: String }

    /// Picker choices as duration text, in display order. The first is not the default; see `LocalModelKeepAlive.default`.
    public static let presets: [(title: String, duration: String)] = [
        ("30 seconds", "30s"), ("5 minutes", "5m"), ("1 hour", "1h"), ("Keep loaded", "-1"),
    ]

    public static func file(root: URL) -> URL { root.appendingPathComponent("models/keep-alive.json") }

    /// The saved choice, or nil when none is saved or the file is unreadable.
    public static func saved(root: URL) -> LocalModelKeepAlive? {
        guard let data = try? Data(contentsOf: file(root: root)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return try? LocalModelKeepAlive(saved.keepAlive)
    }

    /// The saved choice as duration text, for the picker.
    public static func savedText(root: URL) -> String? {
        guard let data = try? Data(contentsOf: file(root: root)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              (try? LocalModelKeepAlive(saved.keepAlive)) != nil else { return nil }
        return saved.keepAlive
    }

    /// Saves `duration`, or restores the default when nil.
    public static func set(_ duration: String?, root: URL) throws {
        let target = file(root: root)
        guard let duration else {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            return
        }
        _ = try LocalModelKeepAlive(duration)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Saved(keepAlive: duration)).write(to: target, options: .atomic)
    }

    /// Explicit flag or environment value, then the saved choice, then 5 minutes.
    public static func effective(explicit: LocalModelKeepAlive?, root: URL) -> LocalModelKeepAlive {
        explicit ?? saved(root: root) ?? .default
    }
}
