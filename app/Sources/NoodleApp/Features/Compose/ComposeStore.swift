import Foundation
import Observation

/// Runs the project actions as real `docker compose` commands and keeps the progress and error words.
@MainActor @Observable
final class ComposeStore {
    private(set) var progress: [String: String] = [:]
    var error: String?

    @ObservationIgnored private let containers: ContainersModel
    @ObservationIgnored private let compose: AIAppsStore.Compose

    init(containers: ContainersModel, compose: @escaping AIAppsStore.Compose) {
        self.containers = containers
        self.compose = compose
    }

    func busy(_ project: ComposeProjectInfo) -> Bool { progress[project.name] != nil }

    func run(_ action: ComposeAction, on project: ComposeProjectInfo) async {
        guard !busy(project) else { return }
        error = nil
        let name = project.name
        Motion.animate { progress[name] = Self.first(action) }
        defer { Motion.animate { progress[name] = nil } }
        let result = await compose(ComposeProjects.arguments(action, for: project)) { [weak self] line in
            guard let words = AIAppProgress.words(for: line) else { return }
            Task { @MainActor in if self?.progress[name] != nil { self?.progress[name] = words } }
        }
        if result.code != 0 {
            let detail = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            error = String(localized: "\(Self.verb(action)) didn't finish for \(name). \(detail)")
        }
        try? await containers.refresh()
    }

    static func verb(_ action: ComposeAction) -> String {
        switch action {
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        case .restart: String(localized: "Restart")
        case .pull: String(localized: "Pull")
        }
    }

    private static func first(_ action: ComposeAction) -> String {
        switch action {
        case .up: String(localized: "Starting the project…")
        case .down: String(localized: "Stopping and removing…")
        case .restart: String(localized: "Restarting…")
        case .pull: String(localized: "Checking for newer images…")
        }
    }
}
