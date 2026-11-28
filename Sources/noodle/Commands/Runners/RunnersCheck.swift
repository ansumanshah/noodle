import Foundation
import NoodleCore

/// Reads the repo's workflows through GitHub's contents API (no clone) and prints one line per job. Edits nothing.
func runnersCheck(_ repo: String, json: Bool = false) {
    guard let token = GitHubToken.fill() else { die("no GitHub sign-in found. Sign in under Settings first.") }
    let api = GitHubRunnersAPI { token }
    do {
        let names = try blocking { try await api.listing(repo, path: ".github/workflows") }.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.sorted()
        guard !names.isEmpty || json else { out("\(repo) has no workflow files."); return }
        var workflows: [(file: String, findings: [String])] = []
        // This Mac's Xcode decides whether an `xcode-N` label matches, read as the helper reads it. Once, only when a label needs it.
        var xcodeAnswer: String??
        for name in names {
            guard let yaml = try blocking({ try await api.file(repo, path: ".github/workflows/" + name) }) else { continue }
            var xcode: String?
            if yaml.lowercased().contains("xcode-") {
                if xcodeAnswer == nil {
                    xcodeAnswer = .some(selectedXcodeMajor() ?? nil)
                }
                xcode = xcodeAnswer ?? nil
            }
            let findings = WorkflowCheck.check(yaml: yaml, file: name, xcodeMajor: xcode)
            let unreadable = findings.isEmpty && (try? KubeYAML.parse(yaml)) == nil
            if json { workflows.append((name, unreadable ? ["\(name): could not be read as a workflow"] : findings.map(\.line))); continue }
            if findings.isEmpty { out(unreadable ? "\(name): could not be read as a workflow" : "\(name): no jobs found") }
            findings.forEach { out($0.line) }
        }
        if json { jsonOut(runnersCheckJSON(repo: repo, workflows: workflows)) }
    } catch { die("cannot read workflows: \(error.localizedDescription)") }
}
