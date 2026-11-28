import SwiftUI
import AppKit

/// List on the left, a fixed detail pane on the right, like the Containers workspace.
struct LinuxMachinesPage: View {
    let env: AppEnvironment
    @State private var showingCreate = false
    @State private var deleting: LinuxMachine?
    @State private var windowVisible = false

    private var store: LinuxMachinesStore { env.machines }
    /// Held in navigation, so the Overview and the menu bar can open a named machine.
    private var selection: String? {
        get { env.nav.selectedMachine }
        nonmutating set { env.nav.selectedMachine = newValue }
    }

    private var rows: [LinuxMachine] {
        let query = env.nav.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items.filter {
            ListFilter.matches(query, $0.name, $0.image)
        }
    }

    private var selected: LinuxMachine? { store.items.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                ErrorBanner(message: error) { store.error = nil }
            }
            if !store.loaded {
                LoadingState(label: String(localized: "Loading machines…")).frame(maxHeight: .infinity)
            } else if store.items.isEmpty {
                EmptyState(symbol: "server.rack", title: String(localized: "No Linux machines"),
                           message: String(localized: "Create an isolated Ubuntu or Alpine environment with its own IP and home folder."),
                           command: "noodle machine create dev --distro ubuntu",
                           action: (String(localized: "New Machine"), store.busy, { showingCreate = true }))
            } else {
                HStack(spacing: 0) {
                    list.frame(minWidth: 190, idealWidth: 260, maxWidth: 300)
                    Divider()
                    detail.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity).background(WorkspaceStyle.content)
                }
            }
        }
        .pageActions([PageAction(id: "new-machine", title: "New Machine", symbol: "plus", disabled: store.busy) { showingCreate = true }])
        .background(MachineWindowVisibility(visible: $windowVisible).frame(width: 0, height: 0))
        .task(id: windowVisible) {
            store.configure(demo: env.demo)
            guard windowVisible else { return }
            await store.refresh()
            guard !env.demo else { return }
            await poll(every: .seconds(3), runFirst: false) { await store.refresh() }
        }
        .task(id: infoKey) { if let machine = selected { await store.loadInfo(for: machine) } }
        .onAppear { if selection == nil { selection = store.items.first?.id } }
        .onChange(of: store.listRevision) { previous, _ in
            selection = store.validatedSelection(selection, after: previous)
        }
        .sheet(isPresented: $showingCreate) { LinuxMachinesCreateSheet(store: store).compactScrollbars() }
        .confirmationDialog("Delete machine “\(deleting?.name ?? "")”?", isPresented: $deleting.isPresent(), titleVisibility: .visible) {
            if let machine = deleting {
                Button("Delete", role: .destructive) {
                    Task { await store.perform("delete", machine: machine) }
                    deleting = nil
                }
            }
        } message: {
            Text("Its disk and everything stored inside it are removed for good. Folders shared from your Mac are not touched.")
        }
        .motion(Motion.standard, value: store.loaded)
        .motion(Motion.standard, value: selection)
        .motion(Motion.standard, value: store.items)
    }

    /// Re-read the extras when the selection or its state changes.
    private var infoKey: String { "\(selection ?? "")|\(selected?.state ?? "")|\(store.loaded)" }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { machine in
                    LinuxMachineRow(machine: machine, pending: store.pending[machine.name])
                        .selectableRow(selected: selection == machine.id) { selection = machine.id }
                        .contextMenu { LinuxMachineMenu(store: store, machine: machine, env: env) { deleting = machine } }
                        .transition(.row)
                }
            }
            .padding(Space.s)
            .selectionKeys(rows.map(\.id), selection: Binding(get: { selection }, set: { selection = $0 }))
        }
        .background(WorkspaceStyle.content)
        .overlay { if rows.isEmpty { EmptyState.search(env.nav.search) } }
    }

    @ViewBuilder private var detail: some View {
        if let machine = selected {
            LinuxMachineDetail(store: store, machine: machine, demo: env.demo) { deleting = machine }
                .id(machine.id)
                .transition(.opacity)
        }
    }
}

struct LinuxMachineRow: View {
    let machine: LinuxMachine
    let pending: String?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name).font(.body).lineLimit(1)
                Text(machine.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            LinuxMachineState(machine: machine, pending: pending)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.name), \(machine.subtitle), \(pending ?? LinuxMachineState.word(machine.state))")
    }
}

/// Green running, orange unfinished, gray stopped. Red is for failures and Stop only.
struct LinuxMachineState: View {
    let machine: LinuxMachine
    let pending: String?

    static func word(_ state: String) -> String { state == "incomplete" ? "Unfinished" : state.capitalized }
    private var color: Color {
        switch machine.state {
        case "running": Status.running
        case "incomplete": Status.warning
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if pending != nil { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: Tile.dot, height: Tile.dot) }
            Text(pending.map { $0 + "…" } ?? Self.word(machine.state))
                .foregroundStyle(machine.isRunning && pending == nil ? Status.running : Color.secondary)
                .contentTransition(.interpolate)
        }
        .font(.callout)
        .motion(Motion.snappy, value: machine.state)
        .motion(Motion.snappy, value: pending)
    }
}

/// Right-click menu for a row. Copies the real command, since machines have no SSH server.
struct LinuxMachineMenu: View {
    let store: LinuxMachinesStore
    let machine: LinuxMachine
    let env: AppEnvironment
    let delete: () -> Void

    var body: some View {
        let usable = machine.state != "incomplete"
        Button("Open Shell", systemImage: "terminal") { store.openShell(machine) }.disabled(!usable || env.demo || store.busy)
        Button("Copy Shell Command", systemImage: "doc.on.doc") {
            copyToPasteboard(machine.shellCommand)
        }
        Divider()
        if machine.isRunning {
            Button("Stop", systemImage: "stop.fill") { Task { await store.perform("stop", machine: machine) } }
                .disabled(store.busy)
            Button("Restart", systemImage: "arrow.clockwise") { Task { await store.perform("restart", machine: machine) } }
                .disabled(store.busy)
        } else if usable {
            Button("Start", systemImage: "play.fill") { Task { await store.perform("start", machine: machine) } }
                .disabled(store.busy)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            .disabled(store.busy)
    }
}
