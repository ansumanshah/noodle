import SwiftUI
import NoodleCore

/// The long-running work behind the assistant: downloads, applying choices and the first container.
extension SetupFlow {
    // MARK: tools

    /// Downloads and checks the missing tools, nothing more. The agent, context, links and PATH wait for the apply step,
    /// after the person has seen what changes. Every file is verified before any is installed, so a stop leaves nothing behind.
    func download() async {
        guard let plan else { return begin() }
        guard detection?.dockerMissing == true else { stage = .engine; return }
        toolsSkipped = false
        stage = .download; problem = nil; progress = nil; downloads = [:]; status = "Downloading…"
        let poller = Task { [weak self] in
            await poll(every: .milliseconds(250)) { self?.pollDownloads() }
        }
        downloadPoller = poller
        let result = await backend.install(["tools", "install", "--no-link", "docker"])
        poller.cancel()
        downloadPoller = nil
        guard !Task.isCancelled else { return backend.discardPartialDownloads() }
        if result.code != 0 { return fail(SetupProblem.classify(code: result.code, output: result.output), from: .download) }
        // Exit 0 is not enough: look again for the tools.
        let after = await backend.detect()
        guard !Task.isCancelled else { return }
        detection = after
        self.plan = .make(after, sizes: plan.sizes)
        if after.dockerMissing { return fail(.dockerMissing, from: .download) }
        downloads = [:]
        stage = .engine
    }

    private func pollDownloads() {
        guard let plan else { return }
        let files = backend.downloadedFiles()
        for pin in Tools.pins where pin.name == "docker" && plan.missing.contains(pin.name) {
            downloads[pin.name] = SetupDownload(done: min(files[pin.file] ?? 0, plan.size(of: pin.name) ?? .max), total: plan.size(of: pin.name))
        }
    }

    // MARK: first container

    /// Applies the choices, starts Noodle and proves docker works against it.
    func install() async {
        guard !abandoned, !Task.isCancelled else { return }
        guard detection != nil else { return begin() }
        stage = .install; problem = nil; progress = nil; status = "Setting up Noodle…"
        applyStartedAt = Date(); applyWait = .setupFiles
        defer { applyStartedAt = nil }
        let addPath = pathOn && pathSupported
        applyingChoices = true
        let result = await backend.install(SetupPlan.flags(download: false, addPath: addPath, useDefault: useDefault))
        applyingChoices = false
        guard !abandoned, !Task.isCancelled else { return }
        status = "Starting Noodle…"
        let facts = result.code == 0 ? await backend.startAndVerify(wantsPath: addPath) { self.applyWait = $0 }
            : SetupFacts(dockerPath: nil, daemonUp: false, dockerReachesNoodle: false)
        guard !abandoned, !Task.isCancelled else { return }
        if let reason = SetupVerdict.evaluate(code: result.code, output: result.output, facts: facts) {
            return fail(reason, from: .install)
        }
        missingTools = SetupVerdict.missingTools(result.output)
        if importOn, importEngine != nil { await importAll() } else { await container() }
    }

    /// A failed import stays on the Import step with its cause. The note on success comes from the CLI's own counts.
    func importAll() async {
        guard let source = importEngine, !importFlags.isEmpty else { return await container() }
        stage = .importing
        let result = await backend.runImport(source.name, flags: importFlags)
        guard !Task.isCancelled else { return }
        if let reason = SetupVerdict.importResult(code: result.code, output: result.output) { return fail(reason, from: .importing) }
        importNote = ImportOutcome.parse(result.output)?.note(from: source.displayName) ?? "Import from \(source.displayName) finished."
        await container()
    }

    func container() async {
        composeCheck = .idle
        stage = .container; pull = PullProgress(); milliseconds = nil; progress = nil
        status = "Fetching a small test image…"
        pulling = true
        let pulled = await backend.pull { [weak self] line in
            Task { @MainActor in if self?.pulling == true { self?.pull.ingest(line) } }
        }
        // A stopped pull already reset this; a newer run may own the flag by now.
        guard !Task.isCancelled else { return }
        pulling = false
        if let reason = SetupVerdict.container(code: pulled.code, output: pulled.output, greeting: "") {
            return fail(reason, from: .container)
        }
        status = "Running it…"
        let ran = await backend.runContainer()
        guard !abandoned, !Task.isCancelled else { return }
        if let reason = SetupVerdict.container(code: ran.result.code, output: ran.result.output, greeting: Self.greeting) {
            return fail(reason, from: .container)
        }
        transcript = ran.result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        milliseconds = ran.milliseconds
        stage = .done
        composeCheck = .checking
        let compose = await backend.checkCompose()
        guard !abandoned, !Task.isCancelled else { return }
        composeCheck = compose.code == 0 ? .available : .failed(compose.output)
    }
}
