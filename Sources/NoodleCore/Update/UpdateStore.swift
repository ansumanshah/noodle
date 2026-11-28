import Foundation

/// On-disk record of a staged or freshly installed update, `<root>/update/state.json`.
/// phases: `staged` (verified and extracted), `installing` (swap journal), `installed` (swapped in, not yet
/// confirmed healthy; `previous` holds the old app for rollback).
public struct UpdateState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case staged, installing, installed }
    public var phase: Phase
    public var version: String
    public var build: Int
    public var stagedApp: String
    public var target: String?
    public var previous: String?
    /// Same-volume swap partner, retained until installed state is committed.
    public var transactionApp: String?
    public var launchAttempts = 0

    public init(phase: Phase, version: String, build: Int, stagedApp: String) {
        self.phase = phase; self.version = version; self.build = build; self.stagedApp = stagedApp
    }
}

public enum UpdateStore {
    public static func dir(_ paths: NoodlePaths) -> URL { paths.root.appendingPathComponent("update", isDirectory: true) }
    public static func downloads(_ paths: NoodlePaths) -> URL { dir(paths).appendingPathComponent("download", isDirectory: true) }
    public static func staging(_ paths: NoodlePaths) -> URL { dir(paths).appendingPathComponent("staged", isDirectory: true) }
    public static func previous(_ paths: NoodlePaths) -> URL { dir(paths).appendingPathComponent("previous", isDirectory: true) }
    static func stateFile(_ paths: NoodlePaths) -> URL { dir(paths).appendingPathComponent("state.json") }

    public static func load(_ paths: NoodlePaths) -> UpdateState? {
        (try? JSONDecoder().decode(UpdateState.self, from: Data(contentsOf: stateFile(paths))))
    }
    public static func save(_ state: UpdateState, _ paths: NoodlePaths) throws {
        try FileManager.default.createDirectory(at: dir(paths), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateFile(paths), options: .atomic)
    }
    public static func clear(_ paths: NoodlePaths) { try? FileManager.default.removeItem(at: stateFile(paths)) }
}
