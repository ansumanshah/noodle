import Foundation

/// The app's Swift sources, shared by the guard suites (design tokens, row and motion rules, localization).
enum AppSources {
    // MARK: - Location

    /// `app/Sources/NoodleApp`.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/NoodleApp", isDirectory: true)

    // MARK: - Walking

    static var swiftFiles: [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Path under `root`, such as `Features/Setup/SetupPage.swift`.
    static func relativePath(_ file: URL) -> String {
        file.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    static func lines(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    }
}
