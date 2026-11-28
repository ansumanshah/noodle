import Foundation

/// Where model weights live: `<root>/models/weights` unless the user picked another folder, for example
/// one on an external drive. The choice is kept in `<root>/models/location.json` so the CLI, daemon and app agree.
/// Models already installed stay where they are; changing the folder only changes where Noodle looks and installs.
public enum ModelLocation {
    private struct Saved: Codable { let path: String }

    public static func file(root: URL) -> URL { root.appendingPathComponent("models/location.json") }
    public static func defaultWeights(root: URL) -> URL { root.appendingPathComponent("models/weights", isDirectory: true) }

    /// The chosen folder, or nil when models use the default inside the Noodle home.
    public static func custom(root: URL) -> URL? {
        guard let data = try? Data(contentsOf: file(root: root)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: saved.path, isDirectory: true)
    }

    public static func weights(root: URL) -> URL { custom(root: root) ?? defaultWeights(root: root) }

    /// Nil when a custom folder is set but missing, such as an unplugged drive. Never create it: creating
    /// `/Volumes/<drive>/…` while the drive is away would fill the startup disk instead.
    public static func unavailable(root: URL) -> URL? {
        guard let url = custom(root: root) else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? nil : url
    }

    /// Saves `url` as the model folder, or restores the default when nil. The folder must exist and be writable.
    public static func set(_ url: URL?, root: URL) throws {
        let target = file(root: root)
        guard let url else {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            return
        }
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelLocationError("\(folder.path) is not a folder")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw ModelLocationError("\(folder.path) is not writable") }
        if folder.path == defaultWeights(root: root).standardizedFileURL.resolvingSymlinksInPath().path { return try set(nil, root: root) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Saved(path: folder.path)).write(to: target, options: .atomic)
    }
}

public struct ModelLocationError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
