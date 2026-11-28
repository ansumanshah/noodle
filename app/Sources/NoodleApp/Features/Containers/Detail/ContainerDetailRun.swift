import SwiftUI

struct RunTab: View {
    let env: AppEnvironment
    let container: ContainerSummary
    @State private var model = RunModel()
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("$").font(.body.monospaced()).foregroundStyle(.secondary)
                    TextField("Run a command in \(container.name)", text: $m.command)
                        .textFieldStyle(.plain).font(.body.monospaced())
                        .focused($focused)
                        .onSubmit { Task { await model.submit(id: container.id, service: env.service) } }
                        .disabled(!container.isRunning)
                    Button("Run") { Task { await model.submit(id: container.id, service: env.service) } }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.primaryAction)
                        .disabled(!container.isRunning || model.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, Space.m).controlSurface()
                VStack(alignment: .leading, spacing: 6) {
                    Text(container.isRunning ? "One-off commands run without a terminal. For an interactive shell:" : "Start the container to run commands.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Shell", systemImage: "terminal") { ContainerActions.openInTerminal(env: env, id: container.id) }
                        .buttonStyle(.neutralAction).disabled(!container.isRunning)
                }
            }
            .padding(Space.panel)
            Divider()
            if model.runs.isEmpty {
                EmptyState(symbol: "terminal", title: String(localized: "No commands run yet"), message: String(localized: "Try uname -a or ls /."), compact: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.runs) { run in RunResult(run: run).transition(.slide(from: .top)) }
                    }
                    .padding(Space.panel)
                }
            }
        }
        .onAppear { focused = container.isRunning }
        .motion(Motion.standard, value: model.runs.count)
    }
}

struct RunResult: View {
    let run: RunModel.Run
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("$ " + run.command).font(.callout.monospaced().weight(.semibold))
                Spacer()
                if run.running { ProgressView().controlSize(.regular) }
                else if let code = run.exitCode, code != 0 { Text("exit \(code)").font(.callout).foregroundStyle(Status.error) }
                else if run.failed == nil, run.exitCode == 0 { Image(systemName: "checkmark.circle.fill").foregroundStyle(Status.running) }
            }
            if let f = run.failed { Text(f).font(.callout).foregroundStyle(Status.error) }
            else if !run.output.isEmpty {
                Text(run.output.trimmingCharacters(in: .newlines)).font(.callout.monospaced())
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.m)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: Radius.panel))
    }
}
