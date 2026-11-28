import NoodleCore
import SwiftUI

/// Runners Overview: on or off, the jobs running now, and the lines to put in a workflow. The CLI owns the work; this
/// page asks it to start and stop. Repos, Jobs and Caches have their own pages.
struct RunnersPage: View {
    let env: AppEnvironment
    @State private var note: String?
    @State private var adding = false
    @Environment(\.openSettings) private var openSettings

    private var list: RunnerRepoList { env.runnerRepos }
    private var state: RunnerState { list.state }
    private var on: Bool { list.on }

    var body: some View {
        VStack(spacing: 0) {
            if let note { ErrorBanner(message: note) { self.note = nil } }
            if list.items.isEmpty {
                EmptyState(symbol: "play.circle", title: String(localized: "Run GitHub Actions on this Mac"),
                           message: String(localized: "Pick a repo, then change one line in its workflow. Jobs start here in seconds, with warm caches, and cost nothing."),
                           command: "noodle runners add",
                           action: (String(localized: "Add Repo"), env.demo, { adding = true }),
                           secondary: (String(localized: "GitHub Sign-In"), {
                               // GitHub sign-in lives on the Docker tab; Settings would otherwise open on the tab it last showed.
                               UserDefaults.standard.set(SettingsView.dockerTab, forKey: SettingsView.selectionKey)
                               openSettings()
                           }))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        status.cardSurface(tinted: false)
                        if !state.running.isEmpty { live }
                        snippets
                    }
                    .padding(Space.page)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .pageSummary(list.items.isEmpty ? nil : Fmt.count(list.items.count, "repo"))
        .sheet(isPresented: $adding) { AddRunnerRepoSheet(env: env, existing: Set(list.items.map(\.repo))) { list.reload(env: env) } }
        .task { await poll(every: .seconds(3)) { list.reload(env: env) } }
        .motion(Motion.standard, value: list.items)
        .motion(Motion.standard, value: on)
        .motion(Motion.standard, value: state.running)
        .motion(Motion.standard, value: state.hold)
        .motion(Motion.standard, value: state.startFailures)
    }

    private var status: some View {
        HStack(spacing: Space.m) {
            Image(systemName: on ? (state.running.isEmpty ? "checkmark.circle.fill" : "play.circle.fill") : "pause.circle")
                .font(.title).foregroundStyle(on ? Status.running : Color.secondary)
                .contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(!on ? "Runners are off" : state.running.isEmpty ? "Waiting for jobs" : "Running \(state.running.count) job(s)")
                    .font(.headline)
                Group {
                    if let message = state.message { Text(message).foregroundStyle(Status.warning) }
                    else if on && state.awake { Text("Keeping this Mac awake until the job ends") }
                    else if on { Text("Checking GitHub every 10 seconds") }
                    else { Text("Nothing runs and nothing polls while off") }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let hold = RunnerRows.holdLine(state, on: on) {
                    Label(hold, systemImage: "pause.circle").font(.callout).foregroundStyle(Status.warning)
                }
                ForEach(RunnerRows.startFailureLines(state, on: on, logDirectory: RunnerStore(paths: env.paths).logDirectory), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Status.warning).textSelection(.enabled)
                }
            }
            Spacer()
            Toggle(String(localized: "Run GitHub jobs on this Mac"), isOn: Binding(get: { on }, set: { toggle($0) }))
                // The demo stays enabled so captures show the real on look; `toggle` ignores it there.
                .labelsHidden().toggleStyle(.tintedSwitch).disabled(list.busy)
        }
        .padding(.vertical, Space.xxs)
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Running now").font(.headline)
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(state.running, id: \.self) { job in
                    HStack(spacing: Space.s) {
                        JobGlyph(job: nil, running: true)
                        Text(job)
                    }
                }
            }
            .cardSurface(tinted: false)
        }
    }

    private var snippets: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("In your workflow").font(.headline)
            VStack(spacing: Space.m) {
                SnippetRow(label: String(localized: "Linux jobs"), text: "runs-on: [self-hosted, noodle]")
                if list.items.contains(where: \.macos) {
                    SnippetRow(label: String(localized: "macOS jobs"), text: "runs-on: [self-hosted, noodle-macos]")
                }
            }
            .cardSurface(tinted: false)
            Text("Each job gets a fresh runner. Linux jobs keep a per-repo cache between runs; macOS jobs use this Mac's Xcode and its caches.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ value: Bool) {
        guard !env.demo else { return }
        Task { note = await list.setOn(value, env: env) }
    }
}
