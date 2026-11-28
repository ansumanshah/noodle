import Foundation

/// The first executable named `name` on PATH, then in the usual user and Homebrew folders. One lookup for the CLI and helpers.
public func findExecutable(_ name: String, environment: [String: String], home: String) -> String? {
    let dirs = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        + ["\(home)/.local/bin", "\(home)/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/local/bin"]
    for d in dirs {
        let p = d + "/" + name
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}
