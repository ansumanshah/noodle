import SwiftUI
import NoodleCore

/// The page for the current step. A failure stays on its own page, with a plain cause and the same list.
struct SetupPage: View {
    let flow: SetupFlow
    var body: some View {
        Group {
            switch flow.current {
            case .tools: SetupToolsPage(flow: flow)
            case .engine: SetupEnginePage(flow: flow)
            case .importItems: SetupImportPage(flow: flow)
            case .first: SetupFirstPage(flow: flow)
            }
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension SetupFlow {
    static let reassurance = "Your current Docker setup stays as it is unless you choose otherwise."

    /// A title, and a line only where a decision needs one. A failure swaps in its cause and the next action.
    var header: (title: String, detail: String) {
        if stage == .failed, let problem { return (problem.title, problem.advice) }
        switch current {
        case .tools: return ("Docker tools", Self.reassurance)
        case .engine: return ("Default engine", toolsSkipped ? Self.reassurance : "Choose what the docker command uses.")
        case .importItems: return ("Bring your Docker data", "Copy from an engine that is already running.")
        case .first: return ("Your first container", "")
        }
    }
}

struct SetupToolsPage: View {
    let flow: SetupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupPageHeader(title: flow.header.title, detail: flow.header.detail)
            if flow.stage == .detect || flow.stage == .plan { SetupChangesLine() }
            SetupList {
                if flow.stage == .detect {
                    ForEach(Array(SetupProbe.tools.enumerated()), id: \.element) { index, name in
                        if index > 0 { SetupRule() }
                        row(SetupTool(name: name, path: nil), checking: true)
                    }
                } else {
                    if let summary = flow.foundSummary {
                        SetupFoundRow(summary: summary, fact: flow.detection?.tool("docker")?.path.map { ($0 as NSString).abbreviatingWithTildeInPath })
                    }
                    ForEach(missing, id: \.name) { tool in
                        if flow.foundSummary != nil || tool.name != missing.first?.name { SetupRule() }
                        row(tool, checking: false)
                    }
                }
            }
            Text("Compose and Buildx download on first use with docker compose or docker build.")
                .font(.callout).foregroundStyle(.secondary)
            if flow.stage == .plan { footer(flow) }
            Spacer(minLength: 0)
        }
    }

    private var missing: [SetupTool] { (flow.detection?.tools ?? []).filter { !$0.found } }
    private func row(_ tool: SetupTool, checking: Bool) -> some View {
        SetupToolRow(tool: tool, pinVersion: Tools.pins.first { $0.name == tool.name }?.version, size: flow.plan?.size(of: tool.name),
                     download: flow.downloads[tool.name], checking: checking, failed: flow.stage == .failed)
    }

    @ViewBuilder private func footer(_ flow: SetupFlow) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Text("Prefer the terminal?").font(.subheadline).foregroundStyle(.secondary)
                SetupCode(text: flow.terminalCommand)
            }
        }
    }
}

struct SetupEnginePage: View {
    let flow: SetupFlow

    var body: some View {
        @Bindable var flow = flow
        let other = flow.currentEngine
        VStack(alignment: .leading, spacing: 20) {
            SetupPageHeader(title: flow.header.title, detail: flow.header.detail)
            // With nothing to download, this is the first page, so it carries the line about what setup changes.
            if flow.toolsSkipped { SetupChangesLine() }
            VStack(alignment: .leading, spacing: Space.s) {
                SetupList {
                    SetupRadioRow(title: other.map { "Keep \($0.displayName) as my default" } ?? "Don’t change my default",
                                  detail: String(localized: "Use Noodle with "), code: "docker --context noodle", selected: !flow.useDefault) { flow.useDefault = false }
                    SetupRule()
                    SetupRadioRow(title: String(localized: "Make Noodle my default"), detail: String(localized: "Same as running "), code: "docker context use noodle",
                                  selected: flow.useDefault) { flow.useDefault = true }
                }
                if flow.toolsSkipped, let summary = flow.foundSummary { Text(summary).font(.subheadline).foregroundStyle(.secondary) }
            }
            if flow.detection?.pathNeeded == true { terminal(flow) }
            HStack(spacing: Space.xs) {
                Text("Prefer the terminal?").font(.subheadline).foregroundStyle(.secondary)
                SetupCode(text: flow.terminalCommand)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func terminal(_ flow: SetupFlow) -> some View {
        @Bindable var flow = flow
        SetupList {
            HStack(alignment: .top, spacing: Space.m) {
                // The label is hidden because the text beside it says the same; VoiceOver still reads it.
                if flow.pathSupported {
                    Toggle("Let new Terminal windows find docker", isOn: $flow.pathOn).toggleStyle(.checkbox).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(flow.pathSupported ? "Let new Terminal windows find docker" : "Terminal needs one line from you").font(.headline)
                    if flow.pathSupported {
                        Text("Adds a marked PATH block to ~/\(flow.profileName)").font(.callout).foregroundStyle(.secondary)
                    } else { InlineCommand(command: SetupPlan.pathLine) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, Space.panel).padding(.vertical, Space.m)
        }
    }
}

struct SetupImportPage: View {
    let flow: SetupFlow

    var body: some View {
        @Bindable var flow = flow
        let engine = flow.importEngine
        VStack(alignment: .leading, spacing: 20) {
            SetupPageHeader(title: flow.header.title, detail: flow.header.detail)
            VStack(alignment: .leading, spacing: Space.m) {
                if flow.importSources.count > 1 {
                    Picker("Source engine", selection: Binding(get: { flow.importEngine?.name }, set: { flow.selectImportSource($0) })) {
                        ForEach(flow.importSources) { source in Text(source.displayName).tag(Optional(source.name)) }
                    }
                    .disabled(flow.stage != .importChoice)
                }
                SetupList {
                    SetupRadioRow(title: String(localized: "Don’t copy anything"), selected: !flow.importOn) { flow.importOn = false }
                    SetupRule()
                    SetupRadioRow(title: String(localized: "Choose what to copy"), detail: String(localized: "From \(engine?.displayName ?? String(localized: "the other engine"))"),
                                  selected: flow.importOn) { flow.importOn = true }
                    if flow.importOn, let inventory = engine?.inventory {
                        ForEach(SetupImportKind.allCases, id: \.self) { kind in
                            let count = kind.count(in: inventory)
                            if count > 0 {
                                Toggle("\(kind.title) (\(count))", isOn: Binding(
                                    get: { flow.importKinds.contains(kind) },
                                    set: { selected in
                                        if selected { flow.importKinds.insert(kind) }
                                        else { flow.importKinds.remove(kind) }
                                    }))
                                    .toggleStyle(.checkbox)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 44).padding(.trailing, Space.panel).padding(.bottom, Space.s)
                            }
                        }
                    }
                }
                .disabled(flow.stage != .importChoice)
                Text("Source data stays in place. Volumes are read through temporary containers that Noodle removes when the copy finishes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if flow.stage == .importing {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text(flow.stopping ? "Stopping…" : "Copying from \(engine?.displayName ?? "the other engine")…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
