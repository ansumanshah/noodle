import SwiftUI
import NoodleCore

/// Moving between pages, retrying, skipping and stopping work.
extension SetupFlow {
    func goBack() {
        switch stage {
        case .engine where !toolsSkipped: stage = .plan
        case .importChoice: stage = .engine
        default: break
        }
    }

    /// "Install Docker myself" is a refused choice, not a silent skip.
    func declineDownload() { fail(.declined, from: .plan) }

    func retry() {
        guard !stopping else { return }
        problem = nil
        switch failedFrom {
        case .download where detection != nil:
            stage = .download
            launch { await self.download() }
        case .install where detection != nil: startInstall()
        case .importing where detection != nil:
            stage = .importing
            launch { await self.importAll() }
        case .container where detection != nil:
            stage = .container
            launch { await self.container() }
        default: begin()
        }
    }

    /// Leaves a failed import behind and goes on to the test container. Nothing was removed from the other engine.
    func skipImport() {
        guard !stopping else { return }
        importNote = importEngine.map { "Import skipped. To copy later, run \(SetupPlan.importCommand(source: $0.name))." }
        importOn = false
        problem = nil
        stage = .container
        launch { await self.container() }
    }

    // MARK: stopping

    /// Stops the work the person is allowed to stop and says what it left behind.
    /// Detecting only reads, so it just ends. Applying the choices is never cut short.
    func stopWork() {
        guard cancellable, !stopping else { return }
        let from = stage
        let running = task
        stopping = true
        downloadPoller?.cancel()
        running?.cancel()
        pulling = false
        // Do not offer Retry until the process exits, including its bounded cleanup grace.
        task = Task {
            await running?.value
            stopping = false
            task = nil
            stopped(from: from)
        }
    }

    private func stopped(from: SetupStage) {
        let engine = importEngine?.displayName ?? "your other engine"
        switch from {
        case .download:
            fail(.stopped("Any tools already checked and saved stay. No Docker context or shell profile changed. Try Again to finish."), from: .download)
        case .importing:
            fail(.stopped("Items already copied stay, and nothing was removed from \(engine). The importer was given time to clean up. Cleanup may be incomplete if it failed or had to be forcibly stopped."),
                 from: .importing)
        case .container:
            fail(.stopped("Noodle is set up. The test container didn’t run. Try Again to finish the test."), from: .container)
        default: break
        }
    }

    /// The window is going away. Work that can stop cleanly does; applying the choices is left to finish.
    func abandon() {
        abandoned = true
        if cancellable { stopWork() }
        else if stage == .done { task?.cancel() }
        else if stage == .install && !applyingChoices { task?.cancel() }
        // An atomic setup application or the short container command can finish,
        // but the flow never starts another step after its window has closed.
    }

    func cancel() { task?.cancel(); task = nil }

    func launch(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await work() }
    }

    func fail(_ reason: SetupProblem, from: SetupStage) {
        problem = reason; failedFrom = from; progress = nil; stage = .failed
    }
}
