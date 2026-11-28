import Foundation
import NoodleCore
import Observation

@MainActor @Observable
final class ModelsPageStore {
    /// The assistants sheet; the window toolbar's assistant menu opens it, the chat page presents it.
    var showsAssistants = false
    enum Activity: Equatable {
        case refresh, prompt, copyKey
        case command(Command)
    }

    struct Problem: Equatable {
        let title: String
        let detail: String
        var retry: Command?
    }

    enum DemoState: Equatable {
        case available, installed, downloading, verifying, starting, running, receiving, failed
        /// Nothing installed: the welcome card and library fit labels. `memoryShort`: the runner refused for memory.
        case firstRun, memoryShort
        case mlxRunning, mlxReceiving
        /// Streams until cancelled, then answers each new prompt with a short canned reply. For cancel checks.
        case streaming
    }

    private(set) var models: [LocalModel] = []
    private(set) var status = LocalModelStatus(phase: .stopped)
    private(set) var activity: Activity?
    private(set) var downloadProgress: LocalModelPullProgress?
    private(set) var cancellingDownload = false
    private(set) var problem: Problem?
    let response = ModelPromptResponse()
    let chat: ModelChatHistory
    let assistants: ModelAssistantStore
    private(set) var generationMetrics: ModelGenerationMetrics?
    private(set) var waitingForMemory = false
    /// The last send was refused for memory; the prompt panel shows a note with Try Again.
    private(set) var memoryRefused = false
    @ObservationIgnored var memoryRetryDelay: Duration = .seconds(10)
    /// The model the picker has chosen. It lives here so the sidebar card's Start acts on the same choice.
    var selectedModelID: String?
    /// What the chat picker offers. Embedding and speech models are served as API only.
    var chatModels: [LocalModel] { models.filter { $0.kind == .chat } }
    var selectedModel: LocalModel? {
        let chat = chatModels
        return chat.first { $0.id == selectedModelID }
            ?? chat.first { $0.id == status.model }
            ?? chat.first { $0.installed }
            ?? chat.first
    }
    var reply: String { response.text }
    let demo: Bool
    /// Only the streaming demo answers prompts; other demo states stay still for captures.
    private let demoChat: Bool
    @ObservationIgnored private var downloadTask: Task<CLI.Result, Error>?
    /// The `noodle model …` boundary. Tests replace it to drive failures and retries without a runner.
    @ObservationIgnored var runCommand: @Sendable ([String], TimeInterval) async -> CLI.Result = { arguments, timeout in
        await CLI.run(arguments, timeout: timeout)
    }

    var busy: Bool { activity != nil }
    /// True when the running model lists the `vision` capability in `GET /v1/models`.
    private(set) var inputSupport = ModelInputSupport()
    var acceptsImages: Bool { inputSupport.images }
    var acceptsVideo: Bool { inputSupport.video }
    /// An installed speech-to-text model that can stand in for a model that can't hear.
    var transcriptionModel: String? { models.first { $0.kind == .speechToText && $0.installed }?.id }
    var canAttachAudio: Bool { inputSupport.audio || (status.phase == .ready && transcriptionModel != nil) }
    var audioUnavailableReason: String {
        String(localized: "The selected model can’t hear audio. Install a speech-to-text model such as Qwen 3 ASR to transcribe it first.")
    }

    init(demo: Bool, demoState: DemoState = .installed, chatHistory: ModelChatHistory? = nil, assistantStore: ModelAssistantStore? = nil) {
        self.demo = demo
        assistants = assistantStore ?? ModelAssistantStore(home: demo ? nil : NoodlePaths.resolve().root)
        demoChat = demo && demoState == .streaming
        chat = chatHistory ?? ModelChatHistory(home: demo ? nil : NoodlePaths.resolve().root)
        guard demo else { return }
        let bytes: UInt64 = 3_349_516_256
        let installed = [.installed, .starting, .running, .receiving, .memoryShort].contains(demoState)
        models = [LocalModel(id: "gemma4", name: "Gemma 4 E2B", bytes: bytes, installed: installed, downloadable: true)]
        switch demoState {
        case .available, .installed:
            break
        case .firstRun:
            models = [LocalModel(id: "qwen3.5-4b", name: "Qwen 3.5 4B", bytes: 3_060_000_000, installed: false, downloadable: true, backend: .mlx),
                      LocalModel(id: "gemma4", name: "Gemma 4 E2B", bytes: bytes, installed: false, downloadable: true),
                      LocalModel(id: "huge-70b", name: "Llama 70B", bytes: 40_000_000_000, installed: false, downloadable: true, backend: .mlx)]
        case .downloading:
            activity = .command(.download("gemma4"))
            downloadProgress = .init(phase: .downloading, receivedBytes: 1_424_000_000, totalBytes: bytes)
        case .verifying:
            activity = .command(.download("gemma4"))
            downloadProgress = .init(phase: .verifying, receivedBytes: bytes, totalBytes: bytes)
        case .starting:
            activity = .command(.start("gemma4"))
        case .running, .receiving, .memoryShort:
            status = .init(phase: .ready, model: "gemma4", baseURL: URL(string: "http://127.0.0.1:11345/v1"),
                           workloadBaseURL: URL(string: "http://192.168.64.1:11345/v1"))
            response.showDemo(text: demoState == .receiving
                              ? "I’m running locally on this Mac. You can"
                              : "I’m running locally on this Mac. You can send requests from a Mac app, a Compose service, or a k3s pod.",
                              receiving: demoState == .receiving)
            if demoState == .receiving { activity = .prompt }
        case .mlxRunning, .mlxReceiving, .streaming:
            models = [LocalModel(id: "qwen3-0.6b-mlx", name: "Qwen 3 0.6B · 4-bit", bytes: 351_383_618,
                                 installed: true, downloadable: true, backend: .mlx)]
            status = .init(phase: .ready, model: "qwen3-0.6b-mlx", baseURL: URL(string: "http://127.0.0.1:11345/v1"),
                           backend: .mlx)
            response.showDemo(text: demoState == .mlxReceiving
                              ? "I’m running Qwen locally on this Mac. You can"
                              : "I’m running Qwen locally on this Mac through MLX.",
                              receiving: demoState == .mlxReceiving)
            if demoState == .mlxReceiving { activity = .prompt }
        case .failed:
            problem = Problem(title: String(localized: "Download failed"),
                              detail: String(localized: "The connection dropped before Gemma 4 E2B finished downloading."),
                              retry: .download("gemma4"))
        }
        if demoState == .memoryShort {
            memoryRefused = true
        }
        if demoState == .streaming {
            Task { await runPrompt("Tell me a story about a lighthouse.", modelID: status.model,
                                   operation: Self.demoStream(Self.demoStory, endless: true)) }
            return
        }
        if [.running, .receiving, .mlxRunning, .mlxReceiving, .memoryShort].contains(demoState) {
            let id = chat.appendUser("Where are you running?", modelID: status.model)
            if demoState == .running || demoState == .mlxRunning || demoState == .memoryShort {
                chat.appendAssistant(response.text, state: .completed, conversationID: id)
            }
        }
    }

    func dismissProblem() { problem = nil }
    func dismissMemoryRefusal() { memoryRefused = false }

    func finishImport(_ result: Result<URL, Error>) async {
        switch result {
        case .success(let url): await importWeights(url)
        case .failure(let error):
            let failure = error as NSError
            guard failure.domain != NSCocoaErrorDomain || failure.code != CocoaError.userCancelled.rawValue else { return }
            problem = Problem(title: String(localized: "Couldn’t import the model"), detail: error.localizedDescription)
        }
    }

    /// Watches the runner while the Models page is visible. Ends when the view's task is cancelled.
    func watchServer(interval: Duration = .seconds(4)) async {
        await poll(every: interval, runFirst: false) { await pollStatus() }
    }

    /// Re-reads only the runner status. A runner that disappeared on its own raises a restartable problem,
    /// and any route change (stopped, restarted, named route lost) replaces what Connections shows.
    func pollStatus(fetch: (() async throws -> LocalModelStatus)? = nil) async {
        guard !demo, !busy else { return }
        let next: LocalModelStatus
        do {
            if let fetch { next = try await fetch() } else {
                let output = try checked(await runCommand(["model", "status", "--json"], 10))
                next = try JSONDecoder().decode(LocalModelStatus.self, from: Data(output.utf8))
            }
        } catch { return }
        // A command may have started while the status call was in flight; it reloads on its own.
        guard !busy, !Task.isCancelled else { return }
        if ModelServerWatch.exitedOnItsOwn(previous: status, current: next), problem == nil {
            problem = Problem(title: String(localized: "The model server stopped"),
                              detail: String(localized: "It exited without being asked to. Start it again to keep using this model."),
                              retry: status.model.map { .start($0) })
        }
        if next != status { status = next }
    }

    func refresh() async {
        guard !demo, !busy else { return }
        activity = .refresh
        defer { activity = nil }
        do {
            try await load()
            problem = nil
        } catch is CancellationError {
        } catch {
            problem = Problem(title: String(localized: "Couldn’t refresh Models"), detail: error.localizedDescription)
        }
    }

    private func load() async throws {
        let run = runCommand
        async let catalog = run(["model", "catalog", "--json"], 10)
        async let service = run(["model", "status", "--json"], 10)
        let (catalogResult, statusResult) = try await (checked(catalog), checked(service))
        try Task.checkCancellation()
        models = try JSONDecoder().decode([LocalModel].self, from: Data(catalogResult.utf8))
        status = try JSONDecoder().decode(LocalModelStatus.self, from: Data(statusResult.utf8))
    }

    func perform(_ command: Command) async {
        guard !demo, !busy else { return }
        if case .download(let id) = command {
            await runDownload(id, operation: { [self] onProgress in
                try await download(command, onProgress: onProgress)
            }, reload: { [self] in try await load() })
            return
        }
        activity = .command(command)
        problem = nil
        response.clear()
        generationMetrics = nil
        defer {
            downloadProgress = nil
            activity = nil
        }
        do {
            let result = await runCommand(["model"] + command.arguments, command.timeout)
            try Task.checkCancellation()
            _ = try checked(result)
        } catch is CancellationError {
            return
        } catch {
            problem = Problem(title: command.failureTitle, detail: error.localizedDescription, retry: command.retry)
        }
        do {
            try await load()
        } catch is CancellationError {
        } catch {
            if problem == nil {
                problem = Problem(title: String(localized: "Couldn’t refresh Models"), detail: error.localizedDescription)
            }
        }
    }

    /// Reserves the activity before spawning, and keeps ownership until cancellation and refresh finish.
    func runDownload(_ id: String,
                     operation: @escaping @MainActor (@escaping @MainActor (LocalModelPullProgress) -> Void) async throws -> CLI.Result,
                     reload: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }
        let command = Command.download(id)
        activity = .command(command)
        problem = nil
        response.clear()
        generationMetrics = nil
        cancellingDownload = false
        let task = Task {
            try Task.checkCancellation()
            return try await operation { [self] progress in
                if !cancellingDownload, downloadProgress != progress { downloadProgress = progress }
            }
        }
        downloadTask = task
        defer {
            downloadTask = nil
            downloadProgress = nil
            cancellingDownload = false
            activity = nil
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !task.isCancelled else { throw CancellationError() }
            _ = try checked(result)
        } catch {
            if Task.isCancelled { return }
            if !task.isCancelled {
                problem = Problem(title: command.failureTitle, detail: error.localizedDescription, retry: command.retry)
            }
        }
        downloadTask = nil
        downloadProgress = nil
        do {
            try await reload()
        } catch is CancellationError {
        } catch {
            if problem == nil { problem = Problem(title: String(localized: "Couldn’t refresh Models"), detail: error.localizedDescription) }
        }
    }

    func cancelDownload() {
        guard case .command(.download) = activity, let downloadTask, !cancellingDownload else { return }
        cancellingDownload = true
        downloadTask.cancel()
    }

    private func download(_ command: Command,
                          onProgress: @MainActor (LocalModelPullProgress) -> Void) async throws -> CLI.Result {
        guard let executable = CLI.locate() else {
            throw ModelPageError(message: String(localized: "The noodle command line tool was not found."))
        }
        let (events, continuation) = AsyncStream<LocalModelPullProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let arguments = ["model"] + command.arguments
        let environment = ProcessInfo.processInfo.environment
        let timeout = command.timeout
        async let result: CLI.Result = {
            defer { continuation.finish() }
            return await CLI.stream(executable: executable.path, arguments, environment: environment, timeout: timeout) { line in
                if let progress = try? JSONDecoder().decode(LocalModelPullProgress.self, from: Data(line.utf8)) {
                    continuation.yield(progress)
                }
            }
        }()
        for await progress in events { onProgress(progress) }
        return await result
    }

    func importWeights(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let slug = stem.replacingOccurrences(of: "[^a-z0-9.-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let id = slug.isEmpty ? "local-model" : String(slug.prefix(63))
        await perform(.importWeights(url, id: id))
    }

    func connectionKey() async -> String? {
        guard !demo, !busy else { return nil }
        activity = .copyKey
        defer { activity = nil }
        do {
            return try await endpoint().apiKey
        } catch {
            problem = Problem(title: String(localized: "Couldn’t copy the API key"), detail: error.localizedDescription)
            try? await load()
            return nil
        }
    }

    /// Asks the running server whether its model reads images. Any failure means no.
    func refreshImageSupport() async {
        guard !demo else {
            let on = status.phase == .ready
            inputSupport = .init(images: on, video: on, audio: on)
            return
        }
        guard status.phase == .ready, let target = try? await endpoint() else { inputSupport = .init(); return }
        var request = URLRequest(url: target.baseURL.appendingPathComponent("models"), timeoutInterval: 5)
        request.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let data = try? await URLSession(configuration: configuration).data(for: request).0
        inputSupport = data.map { ModelChatMedia.support(modelsJSON: $0, model: target.model) } ?? .init()
    }

    /// `attachments` are already reduced by the composer: JPEG images, sampled video frames, 16 kHz WAV audio.
    func test(_ prompt: String, attachments: ModelAttachmentSet = .init()) async {
        if demoChat {
            await runPrompt(prompt, modelID: status.model, attachments: attachments, operation: Self.demoStream(Self.demoReply, endless: false))
            return
        }
        guard !demo, !busy, status.phase == .ready,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // A model that can't hear gets the transcript instead.
        let transcribe: ((ModelAudioClip) async throws -> String)? = inputSupport.audio ? nil : { [self] clip in
            guard let model = transcriptionModel else { throw ModelPromptError(audioUnavailableReason) }
            return try await ModelChatMedia.transcribe(clip, model: model, endpoint: try await endpoint())
        }
        await runPrompt(prompt, modelID: status.model, refreshOnFailure: true, attachments: attachments, transcribe: transcribe) { [self] messages, onText, onMetrics in
            let target = try await endpoint()
            try Task.checkCancellation()
            guard target.model == status.model else {
                throw ModelPromptError("The running model changed. Refresh Models and try again.")
            }
            defer { waitingForMemory = false }
            try await ModelMemoryRefusal.retrying(delay: memoryRetryDelay, onWait: { [self] in waitingForMemory = $0 }) {
                try await ModelPromptStream.send(messages: messages, to: target, settings: chat.current?.settings ?? .init(), onText: onText, onMetrics: onMetrics)
            }
        }
    }

    /// The request boundary is injectable so context and terminal history can be checked without a runner.
    func runPrompt(_ prompt: String, modelID: String?, refreshOnFailure: Bool = false,
                   attachments: ModelAttachmentSet = .init(),
                   transcribe: ((ModelAudioClip) async throws -> String)? = nil,
                   operation: @escaping @MainActor ([LocalModelChat.Message],
                                                   @escaping @MainActor (String) -> Void,
                                                   @escaping @MainActor (ModelGenerationMetrics) -> Void) async throws -> Void) async {
        guard !busy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        guard prompt.utf8.count <= ModelChatHistory.maximumConversationBytes / 2 else {
            problem = Problem(title: String(localized: "Message is too long"), detail: String(localized: "Shorten this message before sending it."))
            return
        }
        activity = .prompt
        problem = nil
        memoryRefused = false
        generationMetrics = nil
        defer { activity = nil }
        if chat.current?.modelID != nil && chat.current?.modelID != modelID { chat.beginNewConversation() }
        let (system, budget) = systemPromptAndBudget()
        let context = chat.current?.requestMessages(fitting: prompt, budget: budget) ?? []
        var attachments = attachments
        attachments.images = Array(attachments.images.prefix(ModelChatAttachments.maximumPerMessage))
        let conversationID = chat.appendUser(prompt, modelID: modelID, attachments: chat.saveAttachments(attachments))
        // Earlier turns go as text only; media rides on the message it was attached to.
        let earlier = (system.isEmpty ? [] : [LocalModelChat.Message(role: .system, content: system)]) + context
        let user = LocalModelChat.Message(role: .user, content: prompt, imageURLs: attachments.images.map(ModelChatAttachments.dataURL),
                                          videos: attachments.video.map { [$0.message] } ?? [],
                                          audios: attachments.audio.map { [$0.message] } ?? [])
        let audio = attachments.audio
        await response.run { [self] onText in
            var user = user
            if let audio, let transcribe { user = user.replacingAudio(with: try await transcribe(audio), source: audio.name) }
            try await operation(earlier + [user], onText) { [self] metrics in generationMetrics = metrics }
        }
        let state: ModelChatMessage.State = switch response.state {
        case .completed: .completed
        case .cancelled: .cancelled
        default: .failed
        }
        chat.appendAssistant(response.text, state: state, conversationID: conversationID)
        if let failure = response.failure {
            if response.memoryRefusal { memoryRefused = true } else {
                problem = Problem(title: String(localized: "Couldn’t send message"), detail: failure)
            }
        }
        activity = nil
        if response.failure != nil, refreshOnFailure { try? await load() }
    }

    /// The server key without the busy state `connectionKey` shows, for work that follows a model switch.
    func serverKey() async -> String? {
        demo ? nil : try? await endpoint().apiKey
    }

    private func endpoint() async throws -> LocalModelEndpoint {
        let output = try checked(await runCommand(["model", "endpoint", "--json"], 10))
        return try JSONDecoder().decode(LocalModelEndpoint.self, from: Data(output.utf8))
    }

    private func checked(_ result: CLI.Result) throws -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.code == 0 else {
            // BoundedInvocation reports a cancelled task as 130; that is a stop, not a failure to show.
            if result.code == 130 { throw CancellationError() }
            if result.code == 124 {
                throw ModelPageError(message: String(localized: "The command timed out. Try again."))
            }
            let details = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("{") }
            let message = details.last(where: { $0.hasPrefix("noodle: ") })?.dropFirst("noodle: ".count) ?? details.last
            throw ModelPageError(message: message.map(String.init) ?? "The model command failed (\(result.code)).")
        }
        return output
    }
}

extension ModelsPageStore {
    func newChat() {
        guard !busy else { return }
        chat.beginNewConversation()
        clearPromptPresentation()
    }

    func selectConversation(_ id: UUID) {
        guard !busy, chat.conversations.contains(where: { $0.id == id }) else { return }
        chat.select(id)
        clearPromptPresentation()
    }

    /// The calling view asks for confirmation before invoking this local deletion.
    func deleteConversation(_ id: UUID) {
        guard !busy else { return }
        let wasSelected = chat.selectedID == id
        chat.delete(id)
        if wasSelected { clearPromptPresentation() }
    }

    private func clearPromptPresentation() {
        response.clear()
        generationMetrics = nil
        problem = nil
        memoryRefused = false
    }

    func cancelPrompt() { response.cancel() }

    func retryLastMessage() async {
        guard let last = chat.current?.messages.last(where: { $0.role == .user }) else { return }
        // After a model switch the send starts a new chat; truncating first would lose the old message.
        if chat.current?.modelID != status.model {
            await test(last.content, attachments: chat.attachmentSet(last.attachments ?? []))
        } else { await resend(last.id, text: last.content) }
    }

    /// A canceled refresh still owns `activity` until it unwinds; wait briefly so a reopened page does not skip its refresh.
    func refreshWhenIdle() async {
        var waited = 0
        while busy, waited < 40, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
        await refresh()
    }

    typealias PromptOperation = @MainActor ([LocalModelChat.Message],
                                            @escaping @MainActor (String) -> Void,
                                            @escaping @MainActor (ModelGenerationMetrics) -> Void) async throws -> Void

    static let demoStory = "The lamp at Gull Point had burned every night for ninety years, and Ines had tended it for thirty of them. "
        + "Each evening she climbed the hundred and twelve steps, wound the clockwork, trimmed the wick and wrote the weather in the log."
    static let demoReply = "Here is a short answer from the demo stream. It finishes on its own."

    /// Emits `text` a word at a time. `endless` repeats it until the task is cancelled, which a fast real model never allows.
    static func demoStream(_ text: String, endless: Bool, interval: Duration = .milliseconds(60)) -> PromptOperation {
        { _, emit, _ in
            let words = text.split(separator: " ").map { $0 + " " }
            repeat {
                for word in words {
                    try await Task.sleep(for: interval)
                    emit(String(word))
                }
            } while endless
        }
    }
}

private struct ModelPageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
