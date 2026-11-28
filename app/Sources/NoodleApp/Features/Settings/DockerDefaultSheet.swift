import NoodleCore
import SwiftUI

/// What the sheet says before it changes anything. Pure, so the wording is testable.
struct DockerDefaultPlan: Equatable {
    /// The saved Docker context `docker` uses now.
    let currentContext: String
    let contextMissing: Bool
    /// DOCKER_HOST or DOCKER_CONTEXT, when set: a shell with it ignores the saved context.
    let override: String?
    /// A running engine with items worth copying, if there is one.
    let source: SetupEngine?

    var currentName: String {
        SetupEngine(name: currentContext, socket: "", reachable: false, inUse: true).displayName
    }
    var undoCommand: String { "docker context use \(currentContext)" }
    var copyKinds: [SetupImportKind] {
        guard let inventory = source?.inventory else { return [] }
        return SetupImportKind.allCases.filter { $0.count(in: inventory) > 0 }
    }
    var copyDetail: String? {
        guard let inventory = source?.inventory, !copyKinds.isEmpty else { return nil }
        let parts = copyKinds.map { kind -> String in
            let count = kind.count(in: inventory)
            let noun: String = switch kind {
            case .images: count == 1 ? "tagged image" : "tagged images"
            case .volumes: count == 1 ? "volume" : "volumes"
            case .containers: count == 1 ? "stopped container" : "stopped containers"
            }
            return "\(count) \(noun)"
        }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1] : parts[0]
    }
}

/// One place to point plain `docker` at Noodle after setup, with the option to copy from the engine it leaves.
struct DockerDefaultSheet: View {
    let env: AppEnvironment
    var preview: DockerDefaultPlan?
    @Environment(\.dismiss) private var dismiss
    @State private var plan: DockerDefaultPlan?
    @State private var copy = false
    @State private var working: String?
    @State private var copying = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use Noodle for docker?").font(.title2.bold())
            if let plan {
                details(plan)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking Docker…").foregroundStyle(.secondary) }
            }
            if let working { HStack { ProgressView().controlSize(.small); Text(working).lineLimit(2) } }
            if let error { Text(error).foregroundStyle(Status.error).textSelection(.enabled).frame(maxHeight: 120) }
            HStack {
                if plan?.contextMissing == true {
                    Button("Add Context Only") { run(addContextOnly) }
                        .disabled(working != nil || env.demo)
                        .help("Adds the noodle context and keeps \(plan?.currentName ?? "your engine") as the default.")
                }
                Spacer()
                // The switch is two short commands and is not interrupted halfway. Only the copy can be stopped.
                Button(copying ? "Stop Copy" : "Cancel") { task?.cancel(); dismiss() }
                    .disabled(working != nil && !copying)
                Button("Use Noodle") { run(switchAndCopy) }
                    .buttonStyle(.primaryAction).keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || working != nil || env.demo)
            }
        }
        .padding(Space.xl)
        .frame(width: 500)
        .task { if plan == nil { plan = preview != nil ? preview : await load() } }
        .onDisappear { task?.cancel() }
        .motion(Motion.snappy, value: working)
        .motion(Motion.snappy, value: plan)
    }

    @ViewBuilder private func details(_ plan: DockerDefaultPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("docker goes to", value: plan.currentName)
            LabeledContent("After this", value: "Noodle")
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: Radius.panel))
        VStack(alignment: .leading, spacing: 8) {
            fact("Changes", "Plain docker and docker compose commands run on Noodle, and what they start appears in this window.")
            fact("Stays", "Everything in \(plan.currentName) stays there, untouched. Nothing is deleted or stopped.")
            VStack(alignment: .leading, spacing: 4) {
                fact("Undo", "Run this in a terminal at any time:")
                CommandBlock(command: plan.undoCommand)
            }
        }
        if let override = plan.override {
            Label("\(override) is set in this environment. A shell with it set ignores the saved context until you unset it.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let source = plan.source, let detail = plan.copyDetail {
            Toggle(isOn: $copy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also copy from \(source.displayName)")
                    Text("\(detail). Names that already exist in Noodle are skipped.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(working != nil)
        }
    }

    private func fact(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.callout.weight(.semibold)).frame(width: 62, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async -> DockerDefaultPlan {
        let backend: any SetupBackend = env.demo ? ScriptedSetupBackend() : LiveSetupBackend(env: env)
        let detection = await backend.detect()
        let saved = await Task.detached { DockerSettingsCommands.contexts().saved }.value
        let own = env.paths.socket.resolvingSymlinksInPath()
        let sources = detection.importable.filter { URL(fileURLWithPath: $0.socket).resolvingSymlinksInPath() != own }
        return DockerDefaultPlan(currentContext: saved, contextMissing: env.connection.noodleContextMissing,
                                 override: detection.dockerOverride,
                                 source: sources.first(where: \.inUse) ?? sources.first)
    }

    /// Runs one step off the button. A returned string is the failure to show; nil closes the sheet.
    private func run(_ step: @escaping () async -> String?) {
        guard task == nil else { return }
        error = nil
        task = Task {
            let failure = await step()
            task = nil
            working = nil
            copying = false
            if Task.isCancelled { return }
            if let failure { error = failure } else { dismiss() }
        }
    }

    private func addContextOnly() async -> String? {
        working = "Adding the noodle context…"
        let paths = env.paths
        guard let docker = await Task.detached(operation: { SetupProbe.discovery(paths).docker() }).value else {
            return "Docker CLI unavailable. Run noodle tools install."
        }
        let added = await DockerSettingsCommands.addContext(docker: docker, socket: paths.socket.path)
        await env.sync.refreshDockerTarget()
        return added.code == 0 ? nil : DockerSettingsCommands.message(added, fallback: "Could not add the noodle context.")
    }

    private func switchAndCopy() async -> String? {
        guard let plan else { return nil }
        working = "Switching docker to Noodle…"
        let paths = env.paths
        guard let docker = await Task.detached(operation: { SetupProbe.discovery(paths).docker() }).value else {
            return "Docker CLI unavailable. Run noodle tools install."
        }
        let switched = await DockerSettingsCommands.selectContext("noodle", docker: docker, socket: paths.socket.path)
        await env.sync.refreshDockerTarget()
        guard switched.code == 0 else {
            return DockerSettingsCommands.message(switched, fallback: "Could not switch the Docker context.")
        }
        guard copy, let source = plan.source, !plan.copyKinds.isEmpty, !Task.isCancelled else { return nil }
        copying = true
        working = "Copying from \(source.displayName). docker already goes to Noodle, so you can keep working."
        let result = await SetupImportInvocation.run("unix://" + source.socket, flags: plan.copyKinds.map(\.flag))
        await env.sync.refreshNow()
        if result.code == 0 || Task.isCancelled { return nil }
        return "docker now goes to Noodle, but the copy did not finish. Retry it in Settings, Import.\n"
            + DockerSettingsCommands.message(result, fallback: "The copy failed.")
    }
}
