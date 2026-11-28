import Foundation

/// Which kind of runner a job needs. Plain `[self-hosted, noodle]` is Linux only; the Mac host has its own label.
public enum RunnerKind: String, Codable, CaseIterable, Sendable {
    case linux, macos

    public var prefix: String { "noodle-\(rawValue)-" }
    /// Most runners of this kind alive at once on this Mac.
    public var cap: Int { self == .linux ? 2 : 1 }
}

public enum RunnerLabels {
    public static let linuxLabel = "noodle", macosLabel = "noodle-macos"
    public static let linux = ["self-hosted", linuxLabel, "linux", "arm64"]

    public static func macos(xcodeMajor: String?) -> [String] {
        ["self-hosted", macosLabel, "macos", "arm64"] + (xcodeMajor.map { ["xcode-\($0)"] } ?? [])
    }

    public static func labels(for kind: RunnerKind, xcodeMajor: String?) -> [String] {
        kind == .linux ? linux : macos(xcodeMajor: xcodeMajor)
    }

    /// "Xcode 26.1\nBuild version 17B55" gives "26".
    public static func xcodeMajor(fromVersionOutput text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Xcode ") }) else { return nil }
        let major = line.dropFirst(6).prefix { $0.isNumber }
        return major.isEmpty ? nil : String(major)
    }

    /// GitHub gives a job to a runner whose labels include every label in `runs-on`. We claim a job only when the
    /// runner we would start can take it, and only when it names a Noodle label, so other self-hosted jobs are left alone.
    public static func kind(forJobLabels labels: [String], xcodeMajor: String?) -> RunnerKind? {
        let wanted = Set(labels.map { $0.lowercased() })
        if wanted.contains(macosLabel) { return wanted.isSubset(of: Set(macos(xcodeMajor: xcodeMajor))) ? .macos : nil }
        if wanted.contains(linuxLabel) { return wanted.isSubset(of: Set(linux)) ? .linux : nil }
        return nil
    }

    /// Why this Mac never takes a job that names a Noodle label, or nil when it would (or the job is not Noodle's).
    public static func refusal(forJobLabels labels: [String], repo: String, macosAllowed: Bool, xcodeMajor: String?) -> String? {
        let wanted = Set(labels.map { $0.lowercased() })
        guard let kind = wanted.contains(macosLabel) ? RunnerKind.macos : wanted.contains(linuxLabel) ? .linux : nil else { return nil }
        if kind == .macos, !macosAllowed {
            return "\(repo): macOS jobs wait because this repo is not enabled for them. Run `noodle runners add \(repo) --macos`."
        }
        if kind == .macos, let xcode = wanted.first(where: { $0.hasPrefix("xcode-") }), xcode != xcodeMajor.map({ "xcode-\($0)" }) {
            return "\(repo): jobs asking for \(xcode) wait: " + (xcodeMajor.map { "this Mac has Xcode \($0)." } ?? "this Mac has no Xcode selected.")
        }
        let extra = wanted.subtracting(kind == .linux ? linux : macos(xcodeMajor: xcodeMajor)).filter { kind == .linux || !$0.hasPrefix("xcode-") }.sorted()
        guard !extra.isEmpty else { return nil }
        let set = (kind == .linux ? linux : macos(xcodeMajor: nil)).joined(separator: ", ")
        return "\(repo): jobs asking for \(extra.joined(separator: ", ")) wait: Noodle's \(kind == .linux ? "Linux" : "macOS") runners have only \(set)."
    }

    /// How many runners to start now: queued jobs not already covered by an idle or starting runner, within the cap.
    public static func startCount(queued: Int, covered: Int, alive: Int, kind: RunnerKind) -> Int {
        max(0, min(queued - covered, kind.cap - alive))
    }
}

/// A shortfall must show on two polls in a row before a runner starts: GitHub keeps listing a job as queued for a
/// moment after a runner took it, and one extra single-use runner would then sit idle.
public struct RunnerPlanner: Sendable {
    private var previous: [String: Int] = [:]
    /// The tick each key last got a start, so a waiting repo goes before one that just had a turn.
    var lastStart: [String: Int] = [:], ticks = 0
    public init() {}

    /// `fresh`: none of our runners exists for this repo and kind, so nothing of ours can have taken the job and
    /// there is no reason to wait a poll.
    public mutating func startCount(key: String, queued: Int, covered: Int, alive: Int, kind: RunnerKind, fresh: Bool = false) -> Int {
        let now = RunnerLabels.startCount(queued: queued, covered: covered, alive: alive, kind: kind)
        defer { previous[key] = now }
        return fresh ? now : min(now, previous[key] ?? 0)
    }

    /// Nothing queued: the next shortfall is a new one and waits its poll.
    public mutating func forget(key: String) { previous[key] = nil }

    /// Forgets the poll count of keys not seen this tick (a paused, removed or skipped repo), so a returning one waits
    /// its poll. The last start is kept, so a repo skipped for a minute does not jump the queue.
    mutating func keep(keys: Set<String>) { previous = previous.filter { keys.contains($0.key) } }

    /// A runner for this key started: the key goes behind those that waited longer. Only after a real start, so a
    /// start that failed keeps the repo's place.
    public mutating func started(key: String) { lastStart[key] = ticks }
}
