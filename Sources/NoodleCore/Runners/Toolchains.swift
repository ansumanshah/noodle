import Foundation

/// The build tools a macOS job sees. `tools` maps a display name to a version; "Xcode" is the selected one.
public struct ToolchainInventory: Codable, Equatable, Sendable {
    public var tools: [String: String]
    /// Installed Xcode versions that are not selected.
    public var otherXcodes: [String]
    public init(tools: [String: String], otherXcodes: [String] = []) { self.tools = tools; self.otherXcodes = otherXcodes }
}

/// The inventory at the last macOS job start, plus what changed at the last start that saw a change.
public struct ToolchainSnapshot: Codable, Equatable, Sendable {
    public var at: Date
    public var inventory: ToolchainInventory
    public var changes: [String]
    public var changedAt: Date?

    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(at) < Toolchains.refreshSeconds }

    public static func recorded(previous: ToolchainSnapshot?, now: ToolchainInventory, at: Date) -> ToolchainSnapshot {
        let found = previous.map { Toolchains.changes(from: $0.inventory, to: now) } ?? []
        if found.isEmpty {
            return ToolchainSnapshot(at: at, inventory: now, changes: previous?.changes ?? [], changedAt: previous?.changedAt)
        }
        return ToolchainSnapshot(at: at, inventory: now, changes: found, changedAt: at)
    }
}

public enum Toolchains {
    /// A snapshot younger than this is reused instead of probing the tools again.
    public static let refreshSeconds: TimeInterval = 300

    /// Display order. Each entry is the name shown, never a path.
    public static let order = ["Xcode", "Swift", "Node", "Bun", "Python", "Rust", "Cargo", "Go", "Ruby", "CocoaPods", "Docker"]

    /// The version in a tool's `--version` output, or nil when none is found.
    public static func version(tool: String, from output: String) -> String? {
        let text = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let patterns = tool == "Swift" ? [#"(?<=Swift version )\d+(?:\.\d+)*"#] : [#"\d+(?:\.\d+)+"#, #"\d+"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
        }
        return nil
    }

    /// Plain-text differences from `old` to `new`, tools in display order, then Xcode installs.
    public static func changes(from old: ToolchainInventory, to new: ToolchainInventory) -> [String] {
        var lines: [String] = []
        let names = order + Set(old.tools.keys).union(new.tools.keys).subtracting(order).sorted()
        for name in names {
            switch (old.tools[name], new.tools[name]) {
            case let (a?, b?) where a != b: lines.append("\(name) \(a) -> \(b)")
            case let (nil, b?): lines.append("\(name) added (\(b))")
            case let (a?, nil): lines.append("\(name) removed (was \(a))")
            default: break
            }
        }
        lines += Set(new.otherXcodes).subtracting(old.otherXcodes).sorted().map { "Xcode \($0) installed" }
        lines += Set(old.otherXcodes).subtracting(new.otherXcodes).sorted().map { "Xcode \($0) removed" }
        return lines
    }

    /// What one probe found. A tool that is not on the PATH is `absent`; one that is there but timed out, failed or
    /// printed nothing readable is `unknown`, and says nothing about whether it changed.
    public enum Probe: Equatable, Sendable { case absent, version(String), unknown }

    /// Versions from a round of probes. An unknown tool keeps its previous version, so a slow probe never reads as removed.
    public static func resolve(_ probes: [String: Probe], previous: [String: String]) -> [String: String] {
        var tools: [String: String] = [:]
        for (name, probe) in probes {
            switch probe {
            case .absent: break
            case let .version(v): tools[name] = v
            case .unknown: tools[name] = previous[name]
            }
        }
        return tools
    }

    /// The changes worth showing: those recorded after the last finished macOS job. Once a job has run on the new
    /// toolchain the line goes away.
    public static func visibleChanges(_ snapshot: ToolchainSnapshot?, lastMacJob: Date?) -> [String] {
        guard let snapshot, let changedAt = snapshot.changedAt else { return [] }
        if let last = lastMacJob, last > changedAt { return [] }
        return snapshot.changes
    }

    public static func xcodeMajor(_ inventory: ToolchainInventory) -> String? {
        inventory.tools["Xcode"].flatMap { $0.split(separator: ".").first.map(String.init) }
    }
}

extension RunnerStore {
    private var toolchainsFile: URL { directory.appendingPathComponent("toolchains.json") }

    public func toolchains() -> ToolchainSnapshot? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ToolchainSnapshot.self, from: Data(contentsOf: toolchainsFile))
    }

    public func saveToolchains(_ snapshot: ToolchainSnapshot) throws {
        try ensure()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: toolchainsFile, options: .atomic)
    }
}
