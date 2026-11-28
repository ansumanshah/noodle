import Foundation
import NoodleCore
import Observation

/// Fixed answers for `--demo-welcome` and the self-test renders. No process, network or file is touched.
@MainActor @Observable
final class ScriptedWelcomeSource: WelcomeSource {
    static let model = LocalModel(id: "qwen3.5-4b", name: "Qwen 3.5 4B", bytes: 3_060_000_000, installed: false, downloadable: true, backend: .mlx)

    var starter: LocalModel? = ScriptedWelcomeSource.model
    var modelReady = false
    var progress: LocalModelPullProgress?
    var downloading: Bool { progress != nil }
    var modelProblem: String?
    var dockerConnected = false
    var repoCount = 0
    var opensSheets: Bool { false }
    /// Steps between progress updates of the pretend download; zero finishes at once.
    @ObservationIgnored var step: Duration = .milliseconds(120)

    func download() {
        guard !modelReady, progress == nil else { return }
        let total = Self.model.bytes
        Task {
            for part in 1...20 {
                progress = .init(phase: .downloading, receivedBytes: total / 20 * UInt64(part), totalBytes: total)
                if step > .zero { try? await Task.sleep(for: step) }
            }
            progress = nil
            modelReady = true
        }
    }

    func finish(_ product: WelcomeProduct) {
        switch product {
        case .models: modelReady = true
        case .containers: dockerConnected = true
        case .runners: repoCount = 1
        }
    }

    func load() async {}
}

/// Named states for `--demo-welcome-state=<name>` and the PNG renders.
@MainActor
enum WelcomePreview {
    nonisolated static let names = ["choose", "ready", "ready-downloading", "ready-done", "done"]

    static func flow(named name: String) -> WelcomeFlow? {
        guard names.contains(name) else { return nil }
        let source = ScriptedWelcomeSource()
        let flow = WelcomeFlow(source: source)
        guard name != "choose" else { return flow }
        flow.chosen = Set(WelcomeProduct.allCases)
        flow.screen = name == "done" ? .done : .ready
        switch name {
        case "ready-downloading":
            source.progress = .init(phase: .downloading, receivedBytes: 1_377_000_000, totalBytes: ScriptedWelcomeSource.model.bytes)
        case "ready-done", "done":
            for product in WelcomeProduct.allCases { source.finish(product) }
        default: break
        }
        return flow
    }
}
