import NoodleCore
import SwiftUI

/// What Runners keeps on disk: each repo's cache volume, the macOS runner install and the job logs.
struct RunnerCachesPage: View {
    let env: AppEnvironment
    @State private var report: RunnerCacheReport?
    @State private var loadError: String?
    @State private var note: String?
    @State private var clearing: String?

    private var list: RunnerRepoList { env.runnerRepos }
    private var rows: [RunnerRows.Cache] {
        report.map { RunnerRows.caches($0, state: list.state, helperActive: list.on) }?
            .filter { ListFilter.matches(env.nav.search, $0.repo ?? $0.volume) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if let note { ErrorBanner(message: note) { self.note = nil } }
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        repoCaches(report)
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("On this Mac").font(.headline)
                            VStack(spacing: Space.m) {
                                sizeRow(String(localized: "macOS runner install"), report.installBytes)
                                Divider()
                                sizeRow(String(localized: "Job logs"), report.logsBytes)
                            }
                            .cardSurface(tinted: false)
                            Text("Logs keep the last \(RunnerState.historyLimit) jobs, \(Fmt.bytes(RunnerStore.logBytesLimit)) at most.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Space.page)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if let loadError {
                EmptyState(symbol: "internaldrive", title: String(localized: "Cache sizes are unavailable"), message: loadError,
                           command: "noodle runners cache")
            } else {
                LoadingState(label: String(localized: "Loading…"))
            }
        }
        .pageSummary(report.map { r in RunnerRows.size(r.volumes.compactMap(\.bytes).reduce(r.installBytes + r.logsBytes, +)) })
        .alert("Clear the cache of \(clearing ?? "")?", isPresented: $clearing.isPresent()) {
            Button("Clear", role: .destructive) { if let repo = clearing { clear(repo) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next job starts cold and downloads its dependencies again.")
        }
        .task { await poll(every: .seconds(15)) { await load() } }
        .motion(Motion.standard, value: report)
    }

    @ViewBuilder private func repoCaches(_ report: RunnerCacheReport) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Repo caches").font(.headline)
            VStack(alignment: .leading, spacing: Space.m) {
                if !report.engine {
                    Text("Cache sizes are unavailable until the engine runs.").foregroundStyle(.secondary)
                } else if report.volumes.isEmpty {
                    Text("No repo has a cache yet. Linux jobs create one on their first run.").foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("No cache matches \u{201C}\(env.nav.search)\u{201D}").foregroundStyle(.secondary)
                }
                ForEach(rows) { cache in
                    cacheRow(cache)
                    if cache.id != rows.last?.id { Divider() }
                }
            }
            .cardSurface(tinted: false)
            Text("Linux jobs keep one cache per repo between runs. Clearing it frees the space; the next job fills it again.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func cacheRow(_ cache: RunnerRows.Cache) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cache.repo ?? cache.volume)
                if let refusal = cache.refusal { Text(refusal).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: Space.s)
            Text(RunnerRows.size(cache.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button("Clear") { clearing = cache.repo }
                .disabled(env.demo || cache.refusal != nil || list.busy)
                .help(cache.refusal ?? String(localized: "Remove this repo's cache volume"))
        }
    }

    private func sizeRow(_ label: String, _ bytes: Int64) -> some View {
        HStack { Text(label); Spacer(); Text(RunnerRows.size(bytes)).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func load() async {
        list.reload(env: env)
        if env.demo { report = RunnerRepoList.demoCache; return }
        let result = await CLI.run(["runners", "cache", "--json"])
        if result.code == 0, let next = try? JSONDecoder().decode(RunnerCacheReport.self, from: Data(result.output.utf8)) {
            if next != report { report = next }
            loadError = nil
        } else if report == nil {
            loadError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func clear(_ repo: String) {
        Task {
            note = await list.run(["runners", "cache", "clear", repo], env: env)
            await load()
        }
    }
}
