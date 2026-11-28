import Foundation
import Observation
import AppKit

@MainActor @Observable
final class RunModel {
    struct Run: Identifiable, Hashable {
        let id = UUID()
        var command: String
        var output = ""
        var exitCode: Int?
        var running = true
        var failed: String?
    }
    var command = ""
    private(set) var runs: [Run] = []

    func submit(id: String, service: any DockerService) async {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        command = ""
        let run = Run(command: text)
        Motion.animate { runs.insert(run, at: 0); if runs.count > 20 { runs.removeLast(runs.count - 20) } }
        do {
            let r = try await service.exec(id, argv: ["sh", "-c", text], timeout: 60)
            update(run.id) { $0.output = r.output; $0.exitCode = r.exitCode; $0.running = false }
        } catch {
            update(run.id) { $0.failed = error.localizedDescription; $0.running = false }
        }
    }

    private func update(_ id: UUID, _ f: (inout Run) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        Motion.animate { f(&runs[i]) }
    }
}
