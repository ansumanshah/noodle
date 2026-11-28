import AppKit
import SwiftUI

/// One project: actions, its services, and every container's log merged into one view.
struct ComposeDetail: View {
    let env: AppEnvironment
    let project: ComposeProjectInfo
    let close: () -> Void
    @State private var confirmDown = DemoFlags.has("--demo-compose-down")
    @State private var removeVolumes = false

    private var store: ComposeStore { env.compose }

    var body: some View {
        let busy = store.busy(project)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Close", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                        .foregroundStyle(.secondary)
                }
                if let progress = store.progress[project.name] {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(progress).font(.callout) }
                        .transition(.opacity)
                }
                actions(busy: busy)
                if !project.canRunFromFiles {
                    Text("Noodle can't find this project's compose file, so Up and Pull are off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Folder", systemImage: "folder") { open(project.directory) }
                        .disabled(project.directory == nil)
                    Button("Open Compose File", systemImage: "doc.text") { open(project.configFiles.first) }
                        .disabled(project.configFiles.isEmpty)
                }
                .buttonStyle(.borderless).hoverFill().controlSize(.small).foregroundStyle(.secondary)
            }
            .padding(Space.m)
            Divider()
            services
            Divider()
            LogsTab(env: env, project: project).frame(minHeight: 200)
        }
        .motion(Motion.snappy, value: store.progress[project.name])
        .sheet(isPresented: $confirmDown) { downSheet }
    }

    private func actions(busy: Bool) -> some View {
        HStack(spacing: Space.s) {
            Button("Up", systemImage: "play.fill") { run(.up) }
                .foregroundStyle(Status.running).disabled(!project.canRunFromFiles)
            Button("Down", systemImage: "stop.fill") { removeVolumes = false; confirmDown = true }
                .foregroundStyle(Status.stopped)
            Button("Restart", systemImage: "arrow.clockwise") { run(.restart) }
            Button("Pull", systemImage: "arrow.down.circle") { run(.pull) }.disabled(!project.canRunFromFiles)
        }
        .buttonStyle(.neutralAction).controlSize(.regular).disabled(busy)
    }

    private var services: some View {
        VStack(spacing: 0) {
            ForEach(project.containers) { c in
                HStack(spacing: 8) {
                    Circle().fill(c.isRunning ? Status.running : c.hasFailed ? Status.error : .secondary.opacity(0.5)).frame(width: Tile.dot, height: Tile.dot)
                        .accessibilityHidden(true)
                    Text(c.service ?? c.name).lineLimit(1)
                    Text(c.image).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ForEach(c.openablePorts) { port in
                        if let url = port.url { Link(destination: url) { Text(verbatim: ":\(port.publicPort ?? 0)") }.font(.callout.monospacedDigit()) }
                    }
                    Text(c.state.capitalized).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.m)
                .frame(minHeight: RowSize.height)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    private var downSheet: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Take down “\(project.name)”?").font(.headline)
            Text("Its containers and network are removed. Images and your project files are kept.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Remove volumes (deletes the project's data)", isOn: $removeVolumes)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirmDown = false }.keyboardShortcut(.cancelAction)
                Button("Down") { confirmDown = false; run(.down(removeVolumes: removeVolumes)) }
                    .buttonStyle(ControlButtonStyle(tint: Status.stopped)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.panel).frame(width: 380)
    }

    private func run(_ action: ComposeAction) { Task { await store.run(action, on: project) } }

    private func open(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
