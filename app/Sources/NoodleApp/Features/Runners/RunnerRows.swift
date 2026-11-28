import NoodleCore
import SwiftUI

/// What the Runners pages list, worked out from the helper's files and the CLI's cache report. Pure, so tests read it.
enum RunnerRows {
    /// A stable selection key for a finished job.
    static func jobID(_ job: RunnerJobRecord) -> String { "\(job.repo)|\(job.name)|\(job.at.timeIntervalSince1970)" }

    /// The history, newest first, matching the toolbar search by repo or job name.
    static func jobs(_ state: RunnerState, search: String) -> [RunnerJobRecord] {
        (state.history ?? []).filter { ListFilter.matches(search, $0.repo, $0.name) }
    }

    /// The Overview's hold line: only while the helper runs, since a stopped helper holds nothing.
    static func holdLine(_ state: RunnerState, on: Bool) -> String? {
        guard on, var hold = state.hold, !hold.isEmpty else { return nil }
        // The helper writes "Holding new jobs: <why>"; keep the why and localise the lead-in.
        let lead = "Holding new jobs: "
        if hold.hasPrefix(lead) { hold.removeFirst(lead.count) }
        return String(localized: "Holding new jobs: \(hold)")
    }

    /// Why runners fail to start, newest first, only while the helper runs.
    static func startFailureLines(_ state: RunnerState, on: Bool, logDirectory: URL) -> [String] {
        guard on else { return [] }
        return (state.startFailures ?? [:]).values.sorted { $0.at > $1.at }.map { $0.line(logDirectory: logDirectory) }
    }

    /// The sidebar card's status word; green only while the helper runs with nothing failing or held.
    static func cardStatus(_ state: RunnerState, on: Bool) -> (text: String, healthy: Bool) {
        guard on else { return (String(localized: "Off"), false) }
        if !(state.startFailures ?? [:]).isEmpty { return (String(localized: "Failing"), false) }
        if holdLine(state, on: on) != nil { return (String(localized: "Holding"), false) }
        return (String(localized: "On"), true)
    }

    static func duration(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// What a log tail shows: at most `maxLines` of the last lines, so a huge log never lays out in full.
    static func logLines(_ text: String?, maxLines: Int = 400) -> String {
        guard let text, !text.isEmpty else { return String(localized: "No log was kept for this job.") }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).joined(separator: "\n")
    }

    struct Cache: Identifiable, Equatable {
        var id: String { volume }
        let repo: String?
        let volume: String
        let bytes: Int64?
        /// Why Clear is off, nil when it may run.
        let refusal: String?
    }

    static func caches(_ report: RunnerCacheReport, state: RunnerState, helperActive: Bool) -> [Cache] {
        report.volumes.map { v in
            let refusal = v.repo.map { RunnerCache.clearRefusal(repo: $0, state: state, helperActive: helperActive) }
                ?? String(localized: "This volume's repo is unknown; remove it with docker volume rm \(v.volume).")
            return Cache(repo: v.repo, volume: v.volume, bytes: v.bytes, refusal: refusal)
        }
        .sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Unknown")
    }

    /// The trust line under a repo: who can trigger jobs, and what a macOS job can touch.
    static func trust(_ repo: RunnerRepo) -> [(label: String, symbol: String, warning: Bool)] {
        var tags: [(String, String, Bool)] = [repo.allowPublic == true
            ? (String(localized: "Public allowed"), "globe", true)
            : (String(localized: "Private only"), "lock", false)]
        if repo.macos { tags.append((String(localized: "macOS runs as you"), "person.crop.circle", true)) }
        if !repo.isEnabled { tags.insert((String(localized: "Paused"), "pause.circle", false), at: 0) }
        return tags
    }
}

/// A small capsule label, orange only for a real warning.
struct RunnerTag: View {
    let label: String
    let symbol: String
    var warning = false
    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium)).foregroundStyle(warning ? AnyShapeStyle(Status.warning) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
            .background((warning ? Status.warning : Color.primary).opacity(0.08), in: Capsule())
    }
}
