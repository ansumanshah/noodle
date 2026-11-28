import Foundation
import Testing

// MARK: - Tags

extension Tag {
    /// Spawns processes, binds sockets or waits on real timers. Fast run: `swift test --skip-tag slow`.
    @Tag static var slow: Self
}

// MARK: - Scratch paths

/// A fresh, unused path in the temp directory. Nothing is created.
func scratchPath(_ name: String = "scratch") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("noodle-\(name)-\(UUID().uuidString.prefix(8))")
}

/// A fresh, created directory in the temp directory.
func scratchDir(_ name: String = "scratch") throws -> URL {
    let url = scratchPath(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Waiting

/// Polls until `condition` holds or `timeout` passes. Returns whether it held, so callers `#expect` or `#require` it.
@discardableResult
func waitUntil(timeout: Duration = .seconds(10), poll: Duration = .milliseconds(10),
               _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: poll)
    }
    return true
}
