import Foundation
import NoodleCore
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelKindTests {
    private let models = [
        LocalModel(id: "chat", name: "Chat", bytes: 1, installed: true, downloadable: true, backend: .mlx),
        LocalModel(id: "embed", name: "Embed", bytes: 1, installed: true, downloadable: true, backend: .mlx, kind: .embeddings),
        LocalModel(id: "stt", name: "STT", bytes: 1, installed: true, downloadable: true, backend: .mlx, kind: .speechToText),
        LocalModel(id: "tts", name: "TTS", bytes: 1, installed: true, downloadable: true, backend: .mlx, kind: .textToSpeech),
        LocalModel(id: "flux", name: "Flux", bytes: 1, installed: true, downloadable: true, backend: .mlx, kind: .imageGeneration),
        LocalModel(id: "ltx", name: "LTX", bytes: 1, installed: false, downloadable: true, backend: .mlx, kind: .videoGeneration),
    ]

    @Test func generationModelsGetTheirOwnChipsAndStayOutOfChat() {
        #expect(models.filter { ModelKindFilter.image.matches($0.kind) }.map(\.id) == ["flux"])
        #expect(models.filter { ModelKindFilter.video.matches($0.kind) }.map(\.id) == ["ltx"])
        let store = ModelsPageStore(demo: true)
        #expect(!store.chatModels.contains { $0.kind != .chat })
        #expect(models.filter { $0.kind.isCreative }.map(\.id) == ["tts", "flux", "ltx"])
        #expect(ModelCreateKind(.imageGeneration) == .image && ModelCreateKind(.textToSpeech) == .speech && ModelCreateKind(.chat) == nil)
    }

    @Test func createOffersOnlyKindsWithAnInstalledModel() {
        let store = ModelCreateStore(models: ModelsPageStore(demo: true),
                                     creations: ModelCreations(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        // The demo set has FLUX.2 and Kokoro installed and LTX only in the catalog.
        #expect(store.kinds == [.image, .speech])
        #expect(store.installed(.video).isEmpty && store.model?.id == "flux2-klein-4b")
    }

    @Test func kindFilterGroupsBothSpeechKindsAndEmbeddingsApart() {
        #expect(models.filter { ModelKindFilter.embeddings.matches($0.kind) }.map(\.id) == ["embed"])
        #expect(models.filter { ModelKindFilter.speech.matches($0.kind) }.map(\.id) == ["stt", "tts"])
    }

    @Test func connectSamplesFollowTheModelKind() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1/v1"))
        #expect(ModelRequestExample.curl.code(baseURL: base, model: "m", kind: .embeddings).contains("/v1/embeddings"))
        let stt = ModelRequestExample.curl.code(baseURL: base, model: "m", kind: .speechToText)
        #expect(stt.contains("/v1/audio/transcriptions") && stt.contains("-F file=@speech.wav"))
        #expect(ModelRequestExample.curl.code(baseURL: base, model: "m", kind: .textToSpeech).contains("/v1/audio/speech"))
        #expect(ModelRequestExample.curl.code(baseURL: base, model: "m").contains("/v1/chat/completions"))
        #expect(ModelRequestExample.curl.code(baseURL: base, model: "m", kind: .imageGeneration).contains("/v1/images/generations"))
        #expect(ModelRequestExample.python.code(baseURL: base, model: "m", kind: .videoGeneration).contains("/v1/video/generations"))
    }
}
