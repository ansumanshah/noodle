import NoodleCore
import SwiftUI

/// The repos Runners serves: what each runs, its last job, who can trigger it, and pause, check and remove.
struct RunnerReposPage: View {
    let env: AppEnvironment
    @State private var note: String?
    @State private var adding = false
    @State private var checks: [String: [String]] = [:]
    @State private var removing: String?

    private var list: RunnerRepoList { env.runnerRepos }
    private var rows: [RunnerRepo] { list.items.filter { ListFilter.matches(env.nav.search, $0.repo) } }

    var body: some View {
        VStack(spacing: 0) {
            if let note { ErrorBanner(message: note) { self.note = nil } }
            if list.items.isEmpty {
                EmptyState(symbol: "arrow.triangle.branch", title: String(localized: "No repos yet"),
                           message: String(localized: "Add a private repo and its jobs run on this Mac."),
                           command: "noodle runners add owner/repo",
                           action: (String(localized: "Add Repo"), env.demo, { adding = true }))
            } else if rows.isEmpty {
                EmptyState.search(env.nav.search)
            } else {
                ScrollView {
                    VStack(spacing: Space.m) {
                        ForEach(rows, id: \.repo) { repo in
                            row(repo)
                            if repo.repo != rows.last?.repo { Divider() }
                        }
                    }
                    .cardSurface(tinted: false)
                    .padding(Space.page)
                }
            }
        }
        .pageSummary(list.items.isEmpty ? nil : Fmt.count(list.items.count, "repo"))
        .sheet(isPresented: $adding) { AddRunnerRepoSheet(env: env, existing: Set(list.items.map(\.repo))) { list.reload(env: env) } }
        .pageActions([PageAction(id: "add-repo", title: "Add Repo", symbol: "plus", iconOnly: false, disabled: env.demo) { adding = true }])
        .alert("Remove \(removing ?? "")?", isPresented: $removing.isPresent()) {
            Button("Remove", role: .destructive) { if let repo = removing { run(["runners", "remove", repo]); checks[repo] = nil } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its jobs stop running on this Mac, and its cache is deleted.")
        }
        .task { await poll(every: .seconds(3)) { list.reload(env: env) } }
        .motion(Motion.standard, value: list.items)
    }

    private func row(_ repo: RunnerRepo) -> some View {
        let last = list.state.lastJobs[repo.repo]
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                JobGlyph(job: last, running: list.state.runningRepos?.contains(repo.repo) == true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.repo).foregroundStyle(repo.isEnabled ? .primary : .secondary)
                    HStack(spacing: Space.xs) {
                        Text(repo.macos ? "Linux + macOS" : "Linux")
                        if let last, let url = URL(string: last.url) {
                            Text("·")
                            Link("\(last.name) \(last.at, format: .relative(presentation: .named))", destination: url).buttonStyle(.link)
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // Wide: tags and actions share a line. Narrow: actions drop below, so the repo name keeps its width.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) { tags(repo); Spacer(minLength: Space.s); actions(repo) }
                VStack(alignment: .leading, spacing: Space.xs) { tags(repo); HStack(spacing: Space.xs) { actions(repo) } }
            }
            .padding(.leading, Space.xl + Space.xxs)
            ForEach(checks[repo.repo] ?? [], id: \.self) {
                Text($0).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func tags(_ repo: RunnerRepo) -> some View {
        HStack(spacing: Space.xs) {
            ForEach(RunnerRows.trust(repo), id: \.label) { RunnerTag(label: $0.label, symbol: $0.symbol, warning: $0.warning) }
        }
    }

    @ViewBuilder private func actions(_ repo: RunnerRepo) -> some View {
        Button(repo.isEnabled ? "Pause" : "Resume") { run(["runners", repo.isEnabled ? "pause" : "resume", repo.repo]) }
            .disabled(env.demo || list.busy)
        Button("Check Workflows") { check(repo.repo) }.disabled(env.demo)
        Button("Remove") { removing = repo.repo }.disabled(env.demo || list.busy)
    }

    private func run(_ args: [String]) {
        Task { note = await list.run(args, env: env) }
    }

    private func check(_ repo: String) {
        Task {
            let result = await CLI.run(["runners", "check", repo])
            checks[repo] = result.output.split(separator: "\n").map(String.init)
        }
    }
}
