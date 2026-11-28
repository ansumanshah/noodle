import SwiftUI

// MARK: - Disk

struct DiskCard: View {
    let env: AppEnvironment
    let model: OverviewModel
    let disk: OverviewDisk

    var body: some View {
        OverviewCard(title: String(localized: "Disk")) {
            Text("\(Fmt.bytes(disk.used)) used").font(.title3.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            if let freed = model.freed {
                Text("Freed \(Fmt.bytes(freed))").font(.callout).foregroundStyle(.secondary).transition(.opacity)
            } else if disk.reclaimable > 0 {
                Text("\(Fmt.bytes(disk.reclaimable)) reclaimable").font(.body.monospacedDigit()).contentTransition(.numericText())
            }
            if disk.canClean {
                Button("Clean Up") { confirm() }
                    .buttonStyle(.neutralAction)
                    .accessibilityHint("Shows what will be removed before anything is deleted")
            }
        }
        .motion(Motion.snappy, value: disk)
        .motion(Motion.snappy, value: model.freed)
    }

    private func confirm() {
        env.nav.confirmation = Confirmation(
            title: String(localized: "Clean up?"),
            message: String(localized: "Removes \(disk.summary) and frees about \(Fmt.bytes(disk.reclaimable)). ")
                + String(localized: "Running containers, tagged images and volumes are kept."),
            confirmLabel: String(localized: "Clean Up")) { await run() }
    }

    private func run() async {
        let socket = env.paths.socket.path
        if env.demo {
            Motion.animate { model.freed = disk.reclaimable }
        } else {
            do {
                Motion.animate { model.freed = nil }
                let freed = try await OverviewDiskSource.cleanUp(socketPath: socket)
                Motion.animate { model.freed = freed }
            } catch { env.connection.message = error.localizedDescription }
        }
        await env.sync.refreshNow()
        model.setDisk(env.demo ? OverviewDisk(used: max(0, disk.used - disk.reclaimable)) : await OverviewDiskSource.load(socketPath: socket))
    }
}

// MARK: - Machines

struct MachinesCard: View {
    let env: AppEnvironment
    let store: LinuxMachinesStore
    private let cap = 5

    var body: some View {
        OverviewCard(title: String(localized: "Machines"), tone: WorkspaceStyle.containers) {
            OverviewRows(items: Array(store.items.prefix(cap))) { m in
                OverviewRow(accessibilityLabel: m.name, value: m.state, action: { env.nav.open(.machine(m.name)) }) {
                    HStack(spacing: 12) {
                        OverviewDot(color: m.isRunning ? Status.running : m.state == "incomplete" ? Status.warning : .gray)
                        Text(m.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(LinuxMachineState.word(m.state)).font(.callout).foregroundStyle(m.isRunning ? Status.running : .secondary)
                    }
                } trailing: { EmptyView() } menu: {
                    if m.isRunning { Button("Open Shell") { store.openShell(m) } }
                    Button("Open Machine") { env.nav.open(.machine(m.name)) }
                    Button("Copy Shell Command") { copyToPasteboard(m.shellCommand) }
                }
            }
            if let first = store.items.first(where: \.isRunning) {
                Button("Open Shell") { store.openShell(first) }.buttonStyle(.neutralAction)
                    .accessibilityLabel("Open shell in \(first.name)")
            }
            if store.items.count > cap {
                Button("Show All \(store.items.count)") { env.nav.open(.route(.machines)) }.buttonStyle(.link)
            }
        }
        .motion(Motion.standard, value: store.items.map(\.state))
    }
}
