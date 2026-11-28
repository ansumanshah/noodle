import Foundation
import NoodleCore

/// Reads the stores the rest of the app uses, so the welcome and the pages always agree.
@MainActor
final class LiveWelcomeSource: WelcomeSource {
    let env: AppEnvironment
    let store: ModelsPageStore

    init(env: AppEnvironment, store: ModelsPageStore) {
        self.env = env
        self.store = store
    }

    var starter: LocalModel? { ModelLibraryPolicy.recommended(store.chatModels) ?? store.chatModels.first(where: \.installed) }
    var modelReady: Bool { store.chatModels.contains(where: \.installed) }
    var downloading: Bool { starter.map { ModelLibraryPolicy.downloadingID(store.activity) == $0.id } ?? false }
    var progress: LocalModelPullProgress? { downloading ? store.downloadProgress : nil }
    var modelProblem: String? {
        guard let problem = store.problem, case .download = problem.retry else { return nil }
        return problem.title
    }
    var dockerConnected: Bool { !env.connection.needsSetup }
    var repoCount: Int { env.runnerRepos.items.count }
    var opensSheets: Bool { true }

    func download() {
        guard let id = starter?.id, !modelReady else { return }
        Task { await store.perform(.download(id)) }
    }

    func finish(_ product: WelcomeProduct) {}

    func load() async {
        env.runnerRepos.reload(env: env)
        if store.models.isEmpty { await store.refresh() }
    }
}
