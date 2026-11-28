import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelLibraryPolicyTests {
    private let catalog = [
        LocalModel(id: "qwen-mlx", name: "Qwen 3 0.6B", bytes: 350_000_000, installed: false, downloadable: true, backend: .mlx),
        LocalModel(id: "gemma4", name: "Gemma 4 E2B", bytes: 3_349_516_256, installed: true, downloadable: true),
        LocalModel(id: "personal", name: "Personal model", bytes: 120, installed: true, downloadable: false),
        LocalModel(id: "missing", name: "Missing import", bytes: 0, installed: false, downloadable: false),
    ]

    @Test func searchMatchesAllWordsAcrossNameIDRuntimeAndFormat() {
        #expect(ModelLibraryPolicy.models(catalog, query: "  QWEN \n mlx  ", filter: .all).map(\.id) == ["qwen-mlx"])
        #expect(ModelLibraryPolicy.models(catalog, query: "Gemma GGUF", filter: .all).map(\.id) == ["gemma4"])
        #expect(ModelLibraryPolicy.models(catalog, query: "personal imported", filter: .all).map(\.id) == ["personal"])
        #expect(ModelLibraryPolicy.models(catalog, query: "qwen GGUF", filter: .all).isEmpty)
    }

    @Test func filtersDistinguishDownloadableFromMissingImportedFiles() {
        #expect(ModelLibraryPolicy.models(catalog, query: "", filter: .installed).map(\.id) == ["gemma4", "personal"])
        #expect(ModelLibraryPolicy.models(catalog, query: "", filter: .available).map(\.id) == ["qwen-mlx"])
        #expect(ModelLibraryPolicy.models(catalog, query: "  \n ", filter: .all).count == catalog.count)
        #expect(ModelLibraryPolicy.models(catalog, query: "gemma", filter: .available).isEmpty)
    }

    @Test func downloadingFilterShowsOnlyTheActiveDownloadAndTheBadgeFollowsIt() {
        #expect(ModelLibraryPolicy.models(catalog, query: "", filter: .downloading).isEmpty)
        let shown = ModelLibraryPolicy.models(catalog, query: "", filter: .downloading, downloading: "qwen-mlx")
        #expect(shown.map(\.id) == ["qwen-mlx"])
        #expect(ModelLibraryPolicy.downloadingID(.command(.download("qwen-mlx"))) == "qwen-mlx")
        #expect(ModelLibraryPolicy.downloadingID(.refresh) == nil)
        #expect(ModelLibraryPolicy.badge(nil) == nil)
        #expect(ModelLibraryPolicy.badge(.init(phase: .downloading, receivedBytes: 42, totalBytes: 100)) == "↓ 42%")
        #expect(ModelLibraryPolicy.badge(.init(phase: .verifying, receivedBytes: 100, totalBytes: 100)) == "↓")
    }

    @Test func realOperationTakesPrecedenceAndStoppedStatusDoesNotClaimRunning() {
        let model = catalog[1]
        let running = LocalModelStatus(phase: .ready, model: model.id)
        #expect(ModelLibraryPolicy.state(model: model, status: running, activity: nil, progress: nil) == .running)
        #expect(ModelLibraryPolicy.state(model: model, status: running, activity: .command(.stop), progress: nil) == .stopping)
        #expect(ModelLibraryPolicy.state(model: model, status: .init(phase: .stopped, model: model.id), activity: nil, progress: nil) == .installed)
        #expect(ModelLibraryPolicy.state(model: model, status: .init(phase: .stopped), activity: .command(.start(model.id)), progress: nil) == .starting)
    }

    @Test func verificationBelongsOnlyToTheModelBeingDownloaded() {
        let progress = LocalModelPullProgress(phase: .verifying, receivedBytes: 1, totalBytes: 1)
        let activity = ModelsPageStore.Activity.command(.download(catalog[0].id))
        #expect(ModelLibraryPolicy.state(model: catalog[0], status: .init(phase: .stopped), activity: activity, progress: progress) == .verifying)
        #expect(ModelLibraryPolicy.state(model: catalog[1], status: .init(phase: .stopped), activity: activity, progress: progress) == .installed)
        #expect(ModelLibraryPolicy.state(model: catalog[3], status: .init(phase: .stopped), activity: nil, progress: nil) == .importNeeded)
    }

    @Test func receiptNeverClaimsCompletionBeforeVerification() {
        #expect(ModelLibraryPolicy.transferFraction(.init(phase: .downloading, receivedBytes: 100, totalBytes: 100)) == 0.99)
        #expect(ModelLibraryPolicy.transferFraction(.init(phase: .downloading, receivedBytes: .max, totalBytes: 1)) == 0.99)
        #expect(ModelLibraryPolicy.transferFraction(.init(phase: .downloading, receivedBytes: 1, totalBytes: 0)) == nil)
        #expect(ModelLibraryPolicy.transferFraction(.init(phase: .verifying, receivedBytes: 100, totalBytes: 100)) == nil)
        #expect(ModelLibraryPolicy.transferFraction(.init(phase: .installed, receivedBytes: 100, totalBytes: 100)) == 1)
        #expect(ModelLibraryPolicy.size(0) == "Size unavailable")
    }
}
