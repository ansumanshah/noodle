import NoodleCore
import SwiftUI

/// Pick a repo from your GitHub account, or type one. The CLI adds it, so the app and terminal share one rule.
struct AddRunnerRepoSheet: View {
    let env: AppEnvironment
    let existing: Set<String>
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [(repo: String, isPrivate: Bool)] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var picked: String?
    @State private var macos = false
    @State private var allowPublic = false
    @State private var busy = false
    @State private var error: String?

    private var repo: String { picked ?? query.trimmingCharacters(in: .whitespaces) }
    /// Known public from the picker. A typed repo is checked by the CLI, which explains if it needs the opt-in.
    private var isPublic: Bool { choices.first { $0.repo == repo }.map { !$0.isPrivate } ?? false }
    private var filtered: [(repo: String, isPrivate: Bool)] {
        choices.filter { !existing.contains($0.repo) && ListFilter.matches(query, $0.repo) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Add a Repo").font(.title3.weight(.semibold))
            TextField(String(localized: "Search your repos or type owner/repo"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { picked = nil }
            Group {
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let loadError {
                    Text(loadError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.repo, selection: $picked) { choice in
                        Label(choice.repo, systemImage: choice.isPrivate ? "lock" : "globe").tag(choice.repo)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(height: 220)
            Toggle(String(localized: "Also run macOS jobs (Xcode builds) on this Mac"), isOn: $macos)
            if macos {
                Text("macOS jobs run as you, outside any sandbox. Enable this only for repos you trust.")
                    .font(.callout).foregroundStyle(Status.warning)
            }
            if isPublic {
                Toggle(String(localized: "Allow a public repo (a pull request from a fork can run code on this Mac)"), isOn: $allowPublic)
            }
            if let error { Text(error).font(.callout).foregroundStyle(Status.error).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.buttonStyle(.primaryAction).keyboardShortcut(.defaultAction)
                    .disabled(busy || !RunnerStore.validRepo(repo) || (isPublic && !allowPublic))
            }
        }
        .padding(Space.page)
        .frame(width: 460)
        .task {
            let result = await CLI.run(["runners", "repos"])
            loading = false
            if result.code == 0 {
                choices = result.output.split(separator: "\n").compactMap {
                    let parts = $0.split(separator: "\t")
                    return parts.count == 2 ? (String(parts[0]), parts[1] == "private") : nil
                }
            } else {
                loadError = String(localized: "Sign in to GitHub in Settings to pick from your repos, or type owner/repo above.")
            }
        }
    }

    private func add() {
        busy = true; error = nil
        let args = ["runners", "add", repo] + (macos ? ["--macos"] : []) + (isPublic && allowPublic ? ["--allow-public"] : [])
        Task {
            let result = await CLI.run(args)
            busy = false
            if result.code == 0 { done(); dismiss() }
            else { error = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
