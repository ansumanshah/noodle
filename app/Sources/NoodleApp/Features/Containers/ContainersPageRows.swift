import SwiftUI

/// Start is green and Stop is red.
struct RowActionButton: View {
    let running: Bool
    let subject: String
    let action: () -> Void

    var body: some View {
        Button(running ? "Stop \(subject)" : "Start \(subject)", systemImage: running ? "stop.fill" : "play.fill", action: action)
            .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
            .foregroundStyle(running ? Status.stopped : Status.running)
            .controlSize(.regular)
            .help(running ? "Stop \(subject)" : "Start \(subject)")
    }
}

struct ContainerRow: View {
    let env: AppEnvironment
    let container: ContainerSummary
    let pending: String?
    let imageSize: Int?
    @State private var hovering = false

    private var age: String? { container.created > 0 ? Fmt.ago(container.created) : nil }
    private var size: String? {
        container.sizeRw.map { "\(Fmt.bytes($0)) writable" } ?? imageSize.map { "\(Fmt.bytes($0)) image" }
    }
    private var image: String? { container.image.isEmpty ? nil : container.image }
    private var metadata: String { [image, size, age].compactMap { $0 }.joined(separator: " · ") }

    var body: some View {
        HStack(spacing: 8) {
            if pending != nil { ProgressView().controlSize(.mini) } else { StateDot(state: container.state) }
            Text(container.service ?? container.name).font(.body.weight(.medium))
                .lineLimit(1).truncationMode(.middle).help(container.name)
                .layoutPriority(1)
                .accessibilityLabel("\(container.name), \(pending ?? container.state)")
            // The fullest detail that fits whole: a narrow list shows the name alone, never a clipped "sh…".
            ViewThatFits(in: .horizontal) {
                detail(metadata)
                detail(image ?? "")
                Color.clear.frame(height: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(metadata)
            // Running is the dot; only a state that needs words gets them.
            if let words = pending ?? (container.isRunning ? nil : container.state.capitalized) {
                Text(words).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            port.fixedSize()
        }
        .overlay(alignment: .trailing) { actions }
        .onHover { hovering = $0 }
        .frame(minHeight: RowSize.height)
        .contentShape(Rectangle())
        .motion(Motion.snappy, value: pending)
        .foregroundStyle(.primary)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The local name when there is one, with the raw port in the tooltip; otherwise the port.
    @ViewBuilder private var port: some View {
        if let name = env.containers.names.link(for: container) {
            Link(destination: name.url) { Text(verbatim: name.host).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
                .buttonStyle(.borderless).hoverFill().foregroundStyle(.tint)
                .accessibilityLabel(Text(verbatim: "Open \(container.name) at \(name.host)"))
                .help(Text(verbatim: "Open \(name.url.absoluteString)" + (container.openablePorts.first?.publicPort.map { " (port \($0))" } ?? "")))
                .disabled(!env.connection.isUp)
        } else if let port = container.openablePorts.first(where: { $0.type == "tcp" }), let url = port.url,
           let number = port.publicPort {
            Link(destination: url) { Text(verbatim: ":\(number)").font(.caption.monospaced()) }
                .buttonStyle(.borderless).hoverFill().foregroundStyle(.tint)
                .accessibilityLabel(Text(verbatim: "Open \(container.name) on localhost port \(number)"))
                .help("Open \(url.absoluteString)")
                .disabled(!env.connection.isUp)
        }
    }

    /// Start or stop, restart and delete in 17 pt slots, like the project header's. They float over the row's right edge while it is hovered.
    private var actions: some View {
        HStack(spacing: ActionSlots.gap) {
            slot { startStop }
            slot {
                Button("Restart Container \(container.name)", systemImage: "arrow.clockwise") {
                    Task { await env.containers.perform(.restart, ids: [container.id]) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().foregroundStyle(.secondary)
                .controlSize(.regular).disabled(pending != nil || !container.isRunning)
                .help("Restart container \(container.name)")
            }
            slot {
                Button("Delete Container \(container.name)", systemImage: "trash") {
                    ContainerActions.confirmRemove(env: env, ids: [container.id])
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().foregroundStyle(.secondary)
                .controlSize(.regular).disabled(pending != nil)
                .help("Delete container \(container.name)")
            }
        }
        // A floating pill, so it reads the same over a plain, hovered or selected row.
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .background(WorkspaceStyle.content, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: Control.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.trailing, Space.xxs)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .motion(Motion.snappy, value: hovering)
    }

    private var startStop: some View {
        RowActionButton(running: container.isRunning, subject: "container \(container.name)") {
            Task { await env.containers.perform(container.isRunning ? .stop : .start, ids: [container.id]) }
        }
        .disabled(pending != nil)
    }

    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: ActionSlots.icon)
    }
}

/// Button slot geometry shared by container rows and project headers.
enum ActionSlots {
    static let icon: CGFloat = 17
    static let gap: CGFloat = 8
    }

/// Shared by row context menu and the Container menu in the menu bar.
struct ContainerMenu: View {
    let env: AppEnvironment
    let ids: [String]
    var body: some View {
        let selected = ids.compactMap { env.containers.container($0) }
        if !selected.isEmpty {
            if selected.contains(where: { !$0.isRunning }) {
                Button("Start", systemImage: "play.fill") { Task { await env.containers.perform(.start, ids: ids) } }
            }
            if selected.contains(where: \.isRunning) {
                Button("Stop", systemImage: "stop.fill") { Task { await env.containers.perform(.stop, ids: ids) } }
                Button("Restart", systemImage: "arrow.clockwise") { Task { await env.containers.perform(.restart, ids: ids) } }
            }
            if selected.count == 1, let c = selected.first {
                Divider()
                if let name = env.containers.names.link(for: c) {
                    Button("Open \(name.host)", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(name.url) }
                }
                if !c.openablePorts.isEmpty {
                    ForEach(c.openablePorts) { p in
                        Button("Open localhost:\(p.publicPort ?? 0)", systemImage: "arrow.up.forward.square") { if let u = p.url { NSWorkspace.shared.open(u) } }
                    }
                }
                Button("Open in Terminal", systemImage: "terminal") { ContainerActions.openInTerminal(env: env, id: c.id) }
                    .disabled(!c.isRunning)
                Button("Copy ID", systemImage: "doc.on.doc") { copy(c.id) }
                Button("Copy Name", systemImage: "doc.on.doc") { copy(c.name) }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { ContainerActions.confirmRemove(env: env, ids: ids) }
        }
    }
    private func copy(_ s: String) {
        copyToPasteboard(s)
    }
}
