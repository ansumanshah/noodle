import Foundation

/// "Allow other devices to use my models", kept in `<root>/models/network.json` so the CLI and app agree.
/// Off by default. The server reads it at launch, so changing it restarts a running server.
public enum ModelNetworkSetting {
    private struct Saved: Codable { let enabled: Bool }

    public static func file(root: URL) -> URL { root.appendingPathComponent("models/network.json") }

    public static func enabled(root: URL) -> Bool {
        guard let data = try? Data(contentsOf: file(root: root)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return false }
        return saved.enabled
    }

    public static func set(_ enabled: Bool, root: URL) throws {
        let target = file(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Saved(enabled: enabled)).write(to: target, options: .atomic)
    }
}

/// The model server key. It is generated once and kept across restarts; `rotate` replaces it.
/// `auth.header` is the same key as a curl header file, so the key never appears in a command line.
public enum ModelAPIKey {
    public static func keyFile(in models: URL) -> URL { models.appendingPathComponent("key") }
    public static func headerFile(in models: URL) -> URL { models.appendingPathComponent("auth.header") }

    /// The saved key, created on first use. An unreadable or malformed key file is replaced.
    @discardableResult
    public static func current(in models: URL) throws -> String {
        if let text = try? String(contentsOf: keyFile(in: models), encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count == 64, key.allSatisfy(\.isHexDigit) {
                // Repair a missing header so curl callers keep working.
                if !FileManager.default.fileExists(atPath: headerFile(in: models).path) { try write(key, in: models) }
                return key
            }
        }
        return try rotate(in: models)
    }

    @discardableResult
    public static func rotate(in models: URL) throws -> String {
        let key = IDs.random64()
        try write(key, in: models)
        return key
    }

    private static func write(_ key: String, in models: URL) throws {
        for (text, url) in [(key + "\n", keyFile(in: models)), ("Authorization: Bearer \(key)\n", headerFile(in: models))] {
            try PrivateFile.write(Data(text.utf8), to: url)
        }
    }
}
