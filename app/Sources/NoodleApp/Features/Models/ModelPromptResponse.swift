import Foundation
import Observation

@MainActor @Observable
final class ModelPromptResponse {
    enum State: Equatable {
        case idle, waiting, receiving, cancelling, completed, cancelled, failed
    }

    private(set) var text = ""
    private(set) var state: State = .idle
    private(set) var failure: String?
    /// Set when the failure was a memory refusal, so callers never match on the message text.
    private(set) var memoryRefusal = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var buffer = ModelStreamBuffer()
    @ObservationIgnored private var cancelFlush: ModelStreamScheduler.Cancel?
    @ObservationIgnored private let scheduler: ModelStreamScheduler

    init(scheduler: ModelStreamScheduler = .live) { self.scheduler = scheduler }

    var canCancel: Bool { state == .waiting || state == .receiving }

    func run(_ operation: @escaping @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void) async {
        guard task == nil else { return }
        let id = UUID()
        runID = id
        buffer = ModelStreamBuffer()
        text = ""
        failure = nil
        memoryRefusal = false
        state = .waiting
        let request = Task { [self] in
            do {
                try Task.checkCancellation()
                try await operation { [weak self] delta in
                    guard !Task.isCancelled, let self, self.runID == id,
                          self.task?.isCancelled != true, self.canCancel else { return }
                    self.receive(delta, run: id)
                }
                flush(run: id)
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ModelPromptError("The model returned an empty response. Try another prompt.")
                }
                state = .completed
            } catch {
                flush(run: id)
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    state = .cancelled
                } else {
                    state = .failed
                    failure = error.localizedDescription
                    memoryRefusal = error is ModelMemoryRefusal
                }
            }
        }
        task = request
        await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
        runID = nil
        task = nil
    }

    private func receive(_ delta: String, run id: UUID) {
        guard !delta.isEmpty else { return }
        if let publication = buffer.append(delta, now: scheduler.now()) {
            cancelFlush?()
            cancelFlush = nil
            text += publication
        } else if cancelFlush == nil {
            cancelFlush = scheduler.schedule(buffer.delay(now: scheduler.now())) { [weak self] in
                guard let self, self.runID == id, self.canCancel,
                      self.task?.isCancelled != true else { return }
                self.flush(run: id)
            }
        }
        state = .receiving
    }

    private func flush(run id: UUID) {
        guard runID == id else { return }
        cancelFlush?()
        cancelFlush = nil
        if let publication = buffer.drain(now: scheduler.now()) { text += publication }
    }

    func cancel() {
        guard canCancel, let task else { return }
        if let runID { flush(run: runID) }
        state = .cancelling
        task.cancel()
    }

    func clear() {
        guard task == nil else { return }
        text = ""
        failure = nil
        memoryRefusal = false
        state = .idle
    }

    func showDemo(text: String, receiving: Bool) {
        guard task == nil else { return }
        self.text = text
        state = receiving ? .receiving : .completed
    }
}
