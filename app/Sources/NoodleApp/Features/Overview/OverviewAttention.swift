import SwiftUI

/// Something that needs the developer now. Only real states: a non-zero exit in the last day, a restart loop,
/// a failing health check, or an engine that is not running.
struct OverviewProblem: Identifiable, Equatable {
    enum Kind { case engine, container }
    let id: String
    let kind: Kind
    let message: String
    let when: Date?
    let containerID: String?
    /// A failing health check is a warning. The container is still running.
    var warning = false
}

enum OverviewProblems {
    /// Exit code from Docker's status text, such as "Exited (1) 4 minutes ago".
    static func exitCode(_ c: ContainerSummary) -> Int? {
        guard c.state == "exited", let open = c.status.firstIndex(of: "("), let close = c.status.firstIndex(of: ")"),
              c.status.hasPrefix("Exited"), open < close else { return nil }
        return Int(c.status[c.status.index(after: open)..<close])
    }

    static let cutoff: TimeInterval = 24 * 3600

    /// A guess from Docker's wording, used until the inspected exit time arrives. Docker says "30 hours ago"
    /// up to 48 hours, so hours are read as numbers.
    private static func recent(_ status: String) -> Bool {
        if ["day", "week", "month", "year"].contains(where: { status.contains($0) }) { return false }
        let words = status.split(separator: " ")
        if let unit = words.firstIndex(where: { $0.hasPrefix("hour") }), unit > 0, let hours = Int(words[unit - 1]) {
            return hours < 24
        }
        return true
    }

    /// Failed containers. 143 is a plain SIGTERM stop, so it does not count. An exit counts for one day, judged by
    /// the inspected exit time once it is known.
    static func failing(_ items: [ContainerSummary], finished: [String: Date] = [:], now: Date = .now) -> [ContainerSummary] {
        items.filter { c in
            switch c.state {
            case "exited":
                guard let code = exitCode(c), code != 0, code != 143 else { return false }
                if let when = finished[c.id] { return now.timeIntervalSince(when) < cutoff }
                return recent(c.status)
            case "dead", "restarting": return true
            case "running": return c.status.contains("(unhealthy)")
            default: return false
            }
        }
    }

    /// Only a stopped container has an exit time worth showing or inspecting.
    static func hasExitTime(_ c: ContainerSummary) -> Bool { c.state == "exited" || c.state == "dead" }

    /// The state in one word. A running container whose health check fails is not simply "Running".
    static func stateLabel(_ c: ContainerSummary) -> String {
        if c.state == "running", c.status.contains("(unhealthy)") { return "Unhealthy" }
        if c.state == "exited", let code = exitCode(c) { return "Exited (code \(code))" }
        return c.state.capitalized
    }

    /// One word for what is wrong with a failed container.
    static func word(_ c: ContainerSummary) -> String {
        switch c.state {
        case "exited": "Exited"
        case "restarting": "Restarting"
        case "dead": "Dead"
        default: "Unhealthy"
        }
    }

    static func message(_ c: ContainerSummary) -> String {
        let name = c.service ?? c.name
        switch c.state {
        case "exited": return "\(name) exited with code \(exitCode(c) ?? 1)"
        case "restarting": return "\(name) keeps restarting"
        case "dead": return "\(name) is dead"
        default: return "\(name) is unhealthy"
        }
    }

    /// Most recent first, three at most.
    @MainActor static func items(_ env: AppEnvironment, finished: [String: Date]) -> [OverviewProblem] {
        var out: [OverviewProblem] = []
        let problems = failing(env.containers.items, finished: finished).map { c in
            OverviewProblem(id: c.id, kind: .container, message: message(c), when: hasExitTime(c) ? finished[c.id] : nil,
                            containerID: c.id, warning: c.state == "running" && c.status.contains("(unhealthy)"))
        }
        // Without a known time a problem is treated as current, so it sorts first.
        let now = Date.now
        out += problems.sorted { ($0.when ?? now) > ($1.when ?? now) }
        return Array(out.prefix(3))
    }
}

struct AttentionRow: View {
    let env: AppEnvironment
    let problem: OverviewProblem

    var body: some View {
        let busy = problem.containerID.map { env.containers.pending[$0] != nil } ?? (env.connection.transition != nil)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { text; Spacer(minLength: 8); actions(busy) }
            VStack(alignment: .leading, spacing: 8) { text; HStack { Spacer(minLength: 0); actions(busy) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .box()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs attention: \(problem.message)")
    }

    private var text: some View {
        HStack(spacing: 12) {
            Circle().fill(problem.warning ? Status.warning : Status.error).frame(width: Tile.dot, height: Tile.dot).accessibilityHidden(true)
            Text(problem.message).font(.headline).lineLimit(1)
            if let when = problem.when {
                Text(Fmt.ago(Int(when.timeIntervalSince1970))).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .modifier(EnterAfter())
    }

    @ViewBuilder private func actions(_ busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            if let id = problem.containerID {
                Button("Logs") { env.nav.open(container: id); env.nav.tab = .logs }.buttonStyle(.neutralAction)
                Button("Restart") { Task { await env.containers.perform(.restart, ids: [id]) } }
                    .buttonStyle(.neutralAction).disabled(busy)
            } else {
                Button("Start") { Task { await env.startDaemon() } }
                    .buttonStyle(ControlButtonStyle(tint: Status.running)).disabled(busy)
            }
        }
        .modifier(EnterAfter())
    }
}
