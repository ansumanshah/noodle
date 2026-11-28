import SwiftUI
import Observation
import NoodleCore

/// One first-run flow: tools, default engine, import, first container.
/// It decides from facts the backend reports and never trusts an exit code on its own.
@MainActor @Observable
final class SetupFlow {
    static let greeting = "Hello from Noodle"

    let backend: any SetupBackend
    var stage: SetupStage = .detect
    var detection: SetupDetection?
    var plan: SetupPlan?
    var pathOn = true
    var useDefault = true
    var importOn = false
    var importSourceName: String?
    var importKinds = Set(SetupImportKind.allCases)
    var defaultReason: String?
    var progress: Double?
    var downloads: [String: SetupDownload] = [:]
    var status = ""
    var problem: SetupProblem?
    var failedFrom: SetupStage = .detect
    var importNote: String?
    var pull = PullProgress()
    var milliseconds: Int?
    var composeCheck: SetupComposeCheck = .idle
    var applyStartedAt: Date?
    var applyWait: SetupApplyWait = .setupFiles
    var transcript = ""
    var missingTools: [String] = []
    /// Nothing to download, so the tools step was skipped without asking.
    var toolsSkipped = false
    /// The real path to the CLI, shown for people who prefer the terminal.
    var terminalPath = "noodle"
    var task: Task<Void, Never>?
    var downloadPoller: Task<Void, Never>?
    var stopping = false
    var abandoned = false
    var applyingChoices = false
    /// True while the test image is being fetched, the only part of the first container that can stop cleanly.
    var pulling = false

    init(backend: any SetupBackend) { self.backend = backend }

    /// Work that is running. Applying the choices (`.install`) and the container itself cannot be stopped midway.
    var busy: Bool { [.detect, .download, .install, .importing, .container].contains(stage) }
    /// Work the person may stop, which leaves nothing half-configured: detecting, downloading, importing and the pull.
    var cancellable: Bool { [.detect, .download, .importing].contains(stage) || (stage == .container && pulling) }
    var pathSupported: Bool { detection.map { SetupPlan.profileName(shell: $0.shell) != nil } ?? false }
    var profileName: String { detection.flatMap { SetupPlan.profileName(shell: $0.shell) } ?? ".zprofile" }
    var importSources: [SetupEngine] { detection?.importable ?? [] }
    var importEngine: SetupEngine? {
        importSources.first { $0.name == importSourceName } ?? detection?.importSource
    }
    var importFlags: [String] {
        SetupImportKind.allCases.filter { $0.count(in: selectedImportInventory) > 0 }.map(\.flag)
    }
    var selectedImportInventory: ImportInventory {
        guard let inventory = importEngine?.inventory else { return ImportInventory() }
        return ImportInventory(images: importKinds.contains(.images) ? inventory.images : 0,
                               volumes: importKinds.contains(.volumes) ? inventory.volumes : 0,
                               containers: importKinds.contains(.containers) ? inventory.containers : 0)
    }

    func selectImportSource(_ name: String?) {
        importSourceName = name
        importKinds = Set(SetupImportKind.allCases)
    }
    /// The engine docker uses today, when it is not Noodle.
    var currentEngine: SetupEngine? { detection?.engines.first(where: \.inUse) }
    var steps: [SetupStep] { SetupStep.allCases.filter { $0 != .importItems || importEngine != nil } }
    /// A failed import stays on the Import step, the page it can be retried or skipped from.
    var current: SetupStep { SetupStep.of(stage == .failed ? (failedFrom == .importing ? .importChoice : failedFrom) : stage) }

    /// The state of each step mark. A failure marks its own step; done marks all.
    func mark(_ step: SetupStep) -> SetupMark {
        if stage == .done { return .done }
        if step.rawValue < current.rawValue { return .done }
        if step == current { return stage == .failed ? .failed : .current }
        return .upcoming
    }

    /// "Found docker, compose and buildx": the tools this Mac already has, in one line.
    var foundSummary: String? {
        let names = (detection?.tools ?? []).filter(\.found).map { $0.name.replacingOccurrences(of: "docker-", with: "") }
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Found " + list
    }

    /// Plain `docker` follows DOCKER_CONTEXT or DOCKER_HOST over the context setup selects, so the command names Noodle then.
    var namesContext: Bool { !useDefault || detection?.dockerOverride != nil }
    /// The command the user can run now, matching the engine choice they made and what overrides it.
    var firstCommand: String {
        "docker \(namesContext ? "--context noodle " : "")run --rm alpine echo \"\(Self.greeting)\""
    }
    var composeCommand: String { "docker \(namesContext ? "--context noodle " : "")compose up" }
    /// Said once the default is chosen but an override still wins.
    var overrideNote: String? {
        guard useDefault, let name = detection?.dockerOverride else { return nil }
        return "\(name) is set, so plain docker still uses that engine. Unset it to use Noodle by default."
    }
    /// The `noodle setup` line for the choices made so far, with --tools whenever a download is needed.
    var terminalCommand: String {
        SetupPlan.terminalCommand(cli: terminalPath, download: false, addPath: pathOn && pathSupported, useDefault: useDefault)
    }
    /// Set when a new Terminal still won't find docker, with the line that fixes it.
    var pathReminder: String? {
        guard let detection, detection.pathNeeded, !(pathOn && pathSupported) else { return nil }
        return SetupPlan.pathLine
    }
    /// Whether any download will happen when Continue is pressed on the tools page.
    var downloadsNow: Bool {
        detection?.dockerMissing == true
    }

    // MARK: navigation

    func begin() {
        abandoned = false
        stage = .detect
        launch { await self.detectAll() }
    }

    func detectAll() async {
        stage = .detect; problem = nil
        let found = await backend.detect()
        guard !Task.isCancelled else { return }
        let missing = found.missing.filter { $0.name == "docker" }.map(\.name)
        let sizes = missing.isEmpty ? [:] : await backend.sizes(of: missing)
        guard !Task.isCancelled else { return }
        detection = found
        plan = .make(found, sizes: sizes)
        let rule = SetupPlan.defaultEngine(found.engines)
        useDefault = rule.on; defaultReason = rule.reason
        importOn = false
        selectImportSource(nil)
        pathOn = found.pathNeeded && SetupPlan.profileName(shell: found.shell) != nil
        terminalPath = backend.terminalPath
        // An unnecessary step is skipped without asking.
        toolsSkipped = found.missing.isEmpty
        stage = toolsSkipped ? .engine : .plan
    }

    func continueFromTools() {
        guard downloadsNow else { stage = .engine; return }
        stage = .download
        launch { await self.download() }
    }
    func continueFromEngine() { if importEngine != nil { stage = .importChoice } else { startInstall() } }
    func continueFromImport() {
        guard !importOn || !importFlags.isEmpty else { return }
        startInstall()
    }
    /// The stage changes before the task runs, so the page cannot accept a second press.
    func startInstall() {
        stage = .install
        launch { await self.install() }
    }

}
