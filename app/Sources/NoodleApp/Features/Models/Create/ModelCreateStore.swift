import AppKit
import Foundation
import NoodleCore
import Observation

/// Create's state: the prompt, the chosen kind and model, the running job and its progress. Models and the server come
/// from the shared `ModelsPageStore`, so Chat and Create start and stop the same runner.
@MainActor @Observable
final class ModelCreateStore {
    struct Progress: Equatable {
        var stage: String?
        var step: Int?
        var total: Int?
        var preview: Data?
    }

    private static var cached: [Bool: ModelCreateStore] = [:]
    static func shared(models: ModelsPageStore) -> ModelCreateStore {
        if let store = cached[models.demo], store.models === models { return store }
        let store = ModelCreateStore(models: models)
        cached[models.demo] = store
        return store
    }
    static func existing(models: ModelsPageStore) -> ModelCreateStore? {
        cached[models.demo].flatMap { $0.models === models ? $0 : nil }
    }

    let models: ModelsPageStore
    let creations: ModelCreations
    var kind: ModelCreateKind = .image
    var modelID: String?
    var prompt = ""
    var options = ModelCreateOptions()
    /// A dropped picture: the next image request edits it instead of starting from nothing.
    var editImage: Data?
    private(set) var progress: Progress?
    private(set) var problem: String?
    private(set) var memoryShort = false
    @ObservationIgnored private var job: Task<Void, Never>?

    init(models: ModelsPageStore, creations: ModelCreations? = nil) {
        self.models = models
        let home = models.demo ? FileManager.default.temporaryDirectory.appendingPathComponent("noodle-demo-create")
            : NoodlePaths.resolve().root
        self.creations = creations ?? ModelCreations(home: home)
        if models.demo, !DemoFlags.empty { prompt = "A paper boat on a quiet pond at sunrise, soft light" }
    }

    var running: Bool { progress != nil }

    /// Every generation model the catalog or this Mac has. The demo shows a fixed set for captures.
    var catalog: [LocalModel] {
        guard models.demo else { return models.models.filter { $0.kind.isCreative } }
        let installed = !DemoFlags.empty
        return [LocalModel(id: "flux2-klein-4b", name: "FLUX.2 klein 4B · images", bytes: 4_619_699_951, installed: installed,
                           downloadable: true, backend: .mlx, kind: .imageGeneration),
                LocalModel(id: "kokoro-82m", name: "Kokoro 82M · text to speech", bytes: 361_760_200, installed: installed,
                           downloadable: true, backend: .mlx, kind: .textToSpeech),
                LocalModel(id: "ltx-2.5-video", name: "LTX 2.5 · video with sound", bytes: 41_640_000_000, installed: false,
                           downloadable: true, backend: .mlx, kind: .videoGeneration)]
    }

    /// Only kinds with an installed model show in the switch.
    var kinds: [ModelCreateKind] { ModelCreateKind.allCases.filter { !installed($0).isEmpty } }
    func installed(_ kind: ModelCreateKind) -> [LocalModel] { catalog.filter { $0.kind == kind.modelKind && $0.installed } }

    var model: LocalModel? {
        let choices = installed(kinds.contains(kind) ? kind : kinds.first ?? kind)
        return choices.first { $0.id == modelID } ?? choices.first
    }

    func dismissProblem() { problem = nil; memoryShort = false }
    func cancel() { job?.cancel() }

    func create() {
        guard !running, let model, let kind = ModelCreateKind(model.kind) else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        problem = nil
        memoryShort = false
        // The same rule the library labels use: a model this Mac cannot hold is refused before anything loads.
        guard ModelMemoryFit(modelBytes: model.bytes) != .tooBig else {
            problem = String(localized: "\(model.name) needs more memory than this Mac has. Pick a smaller model.")
            return
        }
        progress = Progress()
        let body = ModelCreateRequest.body(kind: kind, model: model.id, prompt: text, options: options,
                                           editImage: kind == .image ? editImage : nil)
        job = Task { [self] in
            defer { progress = nil; job = nil }
            guard !models.demo else { return }
            do {
                let endpoint = try await ready(model)
                let request = try ModelCreateRequest.urlRequest(kind: kind, body: body, endpoint: endpoint)
                let output = try await ModelCreateStream.run(request) { [self] event in
                    guard case let .progress(stage, step, total, preview) = event else { return }
                    progress = Progress(stage: stage, step: step, total: total, preview: preview ?? progress?.preview)
                }
                progress?.stage = String(localized: "Saving")
                try await save(output, kind: kind, prompt: text, model: model.id)
            } catch is CancellationError {
            } catch is ModelMemoryRefusal {
                memoryShort = true
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The runner is MLX and running, or this starts it with the chosen model. mlx-serve then loads any installed model by name.
    private func ready(_ model: LocalModel) async throws -> LocalModelEndpoint {
        if models.status.phase != .ready || models.status.backend != .mlx {
            await models.perform(.start(model.id))
            if let failure = models.problem { throw ModelPromptError(failure.detail) }
        }
        let result = await models.runCommand(["model", "endpoint", "--json"], 10)
        guard result.code == 0, let endpoint = try? JSONDecoder().decode(LocalModelEndpoint.self, from: Data(result.output.utf8)) else {
            throw ModelPromptError(String(localized: "The model server isn’t answering. Start it again from the sidebar."))
        }
        return endpoint
    }

    private func save(_ output: ModelCreateOutput, kind: ModelCreateKind, prompt: String, model: String) async throws {
        switch output {
        case .image(let data):
            try creations.add(data, ext: data.starts(with: [0xFF, 0xD8]) ? "jpg" : "png", kind: kind, prompt: prompt, model: model)
        case .audio(let data):
            try creations.add(data, ext: "wav", kind: kind, prompt: prompt, model: model)
        case .frames(let frames):
            let (id, url) = try creations.newFile("mp4")
            try await ModelCreateMux.write(frames, to: url)
            try creations.record(id: id, file: url, kind: kind, prompt: prompt, model: model)
        }
    }
}
