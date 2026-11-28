import NoodleCore
import SwiftUI

/// Recent jobs across every repo, newest first. Selecting one shows the end of its log, read from this Mac only.
struct RunnerJobsPage: View {
    let env: AppEnvironment
    @State private var selectedID: String?
    @State private var log: String?

    private var list: RunnerRepoList { env.runnerRepos }
    private var rows: [RunnerJobRecord] { RunnerRows.jobs(list.state, search: env.nav.search) }
    private var selected: RunnerJobRecord? { rows.first { RunnerRows.jobID($0) == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if (list.state.history ?? []).isEmpty {
                EmptyState(symbol: "list.bullet.rectangle", title: String(localized: "No jobs yet"),
                           message: String(localized: "Jobs show up here once a workflow runs on this Mac. Push a commit to try it."))
            } else if rows.isEmpty {
                EmptyState.search(env.nav.search)
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows.map { (id: RunnerRows.jobID($0), job: $0) }, id: \.id) { id, job in
                                row(job).selectableRow(selected: selectedID == id) { selectedID = id }
                            }
                        }
                        .padding(Space.s)
                        .selectionKeys(rows.map(RunnerRows.jobID), selection: $selectedID)
                    }
                    .frame(minWidth: BuildsPage.listMinWidth, idealWidth: BuildsPage.listMinWidth + 60)
                    detail.frame(minWidth: BuildsPage.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .pageSummary((list.state.history ?? []).isEmpty ? nil : Fmt.count(list.state.history?.count ?? 0, "job"))
        .task { await poll(every: .seconds(3)) { list.reload(env: env) } }
        .task(id: selectedID) { await loadLog() }
        .onChange(of: rows.first.map(RunnerRows.jobID), initial: true) { if selectedID == nil { selectedID = $1 } }
        .motion(Motion.standard, value: selectedID)
    }

    private func row(_ job: RunnerJobRecord) -> some View {
        HStack(spacing: Space.s) {
            JobGlyph(job: RunnerLastJob(name: job.name, url: job.url, conclusion: job.conclusion, at: job.at), running: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(job.repo).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(job.at, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                Text(RunnerRows.duration(job.seconds)).monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var detail: some View {
        if let job = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.panel) {
                    HStack(spacing: Space.s) {
                        Text(job.name).font(.title2.weight(.semibold)).lineLimit(2).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if let url = URL(string: job.url) { Link("Open on GitHub", destination: url).font(.callout) }
                    }
                    Text("\(job.repo) · \(job.kind == .macos ? "macOS" : "Linux") · \(job.conclusion ?? "no result") · \(RunnerRows.duration(job.seconds))")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Log").font(.headline)
                    Text(RunnerRows.logLines(log))
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .box(padding: Space.m)
                }
                .padding(Space.page)
            }
        } else {
            EmptyState(symbol: "list.bullet.rectangle", title: String(localized: "Select a job"), message: "", compact: true)
        }
    }

    private func loadLog() async {
        guard let job = selected else { log = nil; return }
        if env.demo { log = RunnerRepoList.demoLog; return }
        let store = RunnerStore(paths: env.paths)
        // shortcut: the last 32 KB only; a full log viewer would page through the file.
        log = await Task.detached { store.logTail(for: job, maxBytes: 32 << 10) }.value
    }
}
