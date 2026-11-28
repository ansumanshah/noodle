import SwiftUI
import AppKit

/// Fixed detail pane: how to get in, what it costs, and the actions. Only values Noodle can really read are shown.
struct LinuxMachineDetail: View {
    let store: LinuxMachinesStore
    let machine: LinuxMachine
    let demo: Bool
    let delete: () -> Void

    private var info: LinuxMachineInfo? { store.info[machine.name] }
    private var pending: String? { store.pending[machine.name] }
    private var usable: Bool { machine.state != "incomplete" }
    private var accessRows: [(label: String, value: String, noun: String)] {
        var rows: [(String, String, String)] = []
        if usable { rows.append(("Shell", machine.shellCommand, "shell command")) }
        if machine.isRunning, let address = info?.address { rows.append(("IP", address, "IP address")) }
        if let share = info?.sharedFolder { rows.append(("Shared folder", share, "shared folder path")) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, Space.l)
            if !accessRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(accessRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 138) }
                        CopyRow(label: row.label, value: row.value, noun: row.noun)
                    }
                }
                .box(padding: 0)
                .padding(.bottom, Space.m)
            }
            resources
            if !usable {
                Text("Setup did not finish. Delete this machine and create it again.")
                    .foregroundStyle(.secondary).padding(.top, Space.panel)
            }
            Spacer(minLength: 20)
            Divider()
            actions.padding(.top, Space.m)
        }
        .padding(Space.page)
        .motion(Motion.snappy, value: machine.state)
        .motion(Motion.standard, value: info)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(machine.name).font(.title2.weight(.semibold)).lineLimit(1)
                Text(machine.subtitle).font(.callout).foregroundStyle(.secondary)
                LinuxMachineState(machine: machine, pending: pending).padding(.top, 2)
            }
            Spacer()
            Button("Open Shell") { store.openShell(machine) }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(!usable || demo || pending != nil)
                .help(demo ? "Shells are off in demo mode" : "Open a shell in \(machine.name). A stopped machine starts first.")
        }
    }

    private var resources: some View {
        // Same label column as the access rows above, so both panels read as one form.
        // Values take the rest of the row, so "8.2 GiB used of 64 GiB" stays on one line in a narrow pane.
        VStack(alignment: .leading, spacing: Space.s + 2) {
            resource("CPUs", "\(machine.cpus)")
            resource("Memory", machine.memoryText)
            resource("Disk", info?.diskUsed.map { "\($0) used of \(machine.diskText)" } ?? machine.diskText)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .box()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resources: \(machine.cpus) CPUs, \(machine.memoryText) memory, \(diskText)")
    }

    private func resource(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            // The label gives way first, so a narrow pane keeps "4 GiB" whole.
            Text(label).foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 64, maxWidth: 110, alignment: .leading)
            Text(value).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
    }

    private var diskText: String {
        guard let used = info?.diskUsed else { return "\(machine.diskText) disk" }
        return "\(used) used of \(machine.diskText) disk"
    }

    /// Labels when they fit; icon-only (with the label as help and accessibility name) in a narrow detail pane.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(labels: true).fixedSize(horizontal: true, vertical: false)
            actionRow(labels: false)
        }
        .disabled(store.busy)
    }

    private func actionRow(labels: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if machine.isRunning {
                action("Stop", "stop.fill", Status.stopped, labels) { run("stop") }
                action("Restart", "arrow.clockwise", .primary, labels) { run("restart") }
            } else if usable {
                action("Start", "play.fill", Status.running, labels) { run("start") }
            }
            action("Delete", "trash", .primary, labels, delete)
        }
    }

    @ViewBuilder
    private func action(_ title: String, _ symbol: String, _ tint: Color, _ labels: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        if labels {
            Button(title, systemImage: symbol, action: perform).buttonStyle(ControlButtonStyle(tint: tint))
        } else {
            Button(action: perform) { Image(systemName: symbol) }
                .buttonStyle(ControlButtonStyle(tint: tint)).help(title).accessibilityLabel(title)
        }
    }

    private func run(_ action: String) { Task { await store.perform(action, machine: machine) } }
}

/// A key and a value in SF Mono with a copy button. The check mark is the confirmation.
private struct CopyRow: View {
    let label: String
    let value: String
    let noun: String
    @State private var copied = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @AppStorage("terminalTheme") private var theme = "github"
    @Environment(\.colorScheme) private var scheme

    /// Under this width the label sits above the value, so a long command, address or path gets the full line.
    @State private var stacked = false
    private static let stackedWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 12) {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    valueView
                }
            } else {
                Text(label).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                valueView
            }
            Spacer(minLength: 8)
            Button { copy() } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc").symbolRenderingMode(.monochrome)
            }
                .buttonStyle(.borderless).hoverFill()
                .foregroundStyle(copied ? Status.running : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .help("Copy \(noun)").accessibilityLabel("Copy \(noun)")
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.stackedWidth } action: { stacked = $0 }
        .frame(minHeight: 24)
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s + 2)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .focused($focused)
        .onHover { hovering = $0; if !$0 { copied = false } }
        .onChange(of: value) { copied = false }
        .onChange(of: focused) { if !focused { copied = false } }
        .motion(Motion.snappy, value: copied)
        .autoReset($copied, to: false)
        .motion(Motion.snappy, value: hovering)
        .contextMenu { Button("Copy \(noun.capitalized)") { copy() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    /// One line in every row. Middle truncation keeps both ends of a command, address or path; selecting the text
    /// or the copy button takes the full value, and the tooltip shows it.
    @ViewBuilder private var valueView: some View {
        let text = label == "Shell"
            ? Text(CommandHighlight.text(value, palette: (TerminalTheme(rawValue: theme) ?? .github).palette(dark: scheme == .dark)))
            : Text(value)
        text.font(stacked ? .callout.monospaced() : .body.monospaced()).textSelection(.enabled)
            .lineLimit(1).truncationMode(.middle).help(value)
    }

    private func copy() {
        copyToPasteboard(value)
        copied = true
    }
}
