import SwiftUI
import AppKit

// MARK: - Ports

/// What a published port can do. The daemon only reports numbers, so the rule is deliberately conservative:
/// a known database or queue port is never offered to a browser, a known web port is, and anything else copies.
enum PortKind {
    case web, other

    private static let webPorts: Set<Int> = [80, 443, 3000, 3001, 4000, 4200, 5000, 5173, 8000, 8008, 8080, 8081, 8443, 8888, 9000, 9001]
    private static let dataStores: [String] = ["postgres", "mysql", "mariadb", "redis", "mongo", "memcached", "rabbitmq", "kafka", "cassandra"]

    static func of(_ endpoint: PortEndpoint, image: String) -> PortKind {
        let lower = image.lowercased()
        if !endpoint.isTCP || dataStores.contains(where: lower.contains) { return .other }
        return webPorts.contains(endpoint.privatePort) ? .web : .other
    }
}

struct PortsCard: View {
    let env: AppEnvironment
    private let cap = 5

    struct Entry: Identifiable {
        let owner: String
        let endpoint: PortEndpoint
        let kind: PortKind
        let containerID: String
        var id: String { containerID + endpoint.id }
        var address: String { endpoint.shown }
    }

    static func entries(_ items: [ContainerSummary], names: LocalNameTable = LocalNameTable()) -> [Entry] {
        items.flatMap { c in
            PortEndpoint.list(c, names: names).map { Entry(owner: c.service ?? c.name, endpoint: $0, kind: PortKind.of($0, image: c.image), containerID: c.id) }
        }
    }

    var body: some View {
        let entries = Self.entries(env.containers.items, names: env.containers.names)
        OverviewCard(title: String(localized: "Ports")) {
            OverviewRows(items: Array(entries.prefix(cap))) { OverviewPortRow(env: env, entry: $0) }
            if entries.count > cap {
                Button("Show All \(entries.count)") { env.nav.selectedProject = nil; env.nav.route = .containers }
                    .buttonStyle(.link)
            }
        }
        .motion(Motion.standard, value: entries.map(\.id))
    }
}

private struct OverviewPortRow: View {
    let env: AppEnvironment
    let entry: PortsCard.Entry
    @State private var copied = false

    var body: some View {
        OverviewRow(accessibilityLabel: entry.kind == .web ? "Open \(entry.address)" : "Copy \(entry.address)",
                    value: entry.owner, action: primary) {
            HStack(spacing: 8) {
                Text(verbatim: entry.address).font(.body.monospaced()).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(entry.owner).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark.circle.fill" : (entry.kind == .web ? "arrow.up.forward.square" : "doc.on.doc"))
                    .symbolRenderingMode(.monochrome).imageScale(.medium).foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
        } trailing: { EmptyView() } menu: {
            if entry.kind == .web { Button("Open in Browser") { open() } }
            Button("Copy Address") { duplicate() }
            Button("Open Container") { env.nav.open(container: entry.containerID) }
        }
        .help(entry.kind == .web ? "Open in browser" : "Copy address")
        .motion(Motion.snappy, value: copied)
        .autoReset($copied, to: false)
    }

    private func primary() { entry.kind == .web ? open() : duplicate() }
    private func open() { if let url = entry.endpoint.url { NSWorkspace.shared.open(url) } }
    private func duplicate() {
        copyToPasteboard(entry.address)
        copied = true
    }
}

// MARK: - Memory

struct MemoryCard: View {
    let env: AppEnvironment
    let model: OverviewModel

    private struct Entry: Identifiable { let id: String; let name: String; let bytes: Int }

    var body: some View {
        let top = model.memory.compactMap { id, bytes in
            env.containers.container(id).map { Entry(id: id, name: $0.service ?? $0.name, bytes: bytes) }
        }
        .sorted { $0.bytes > $1.bytes }.prefix(3)
        OverviewCard(title: String(localized: "Memory")) {
            Text(Fmt.bytes(model.total)).font(.title3.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
            if model.uncounted > 0 {
                Text("\(model.tracked - model.uncounted) of \(model.tracked) containers counted").font(.callout).foregroundStyle(.secondary)
            }
            OverviewRows(items: Array(top)) { e in
                OverviewRow(accessibilityLabel: e.name, value: Fmt.bytes(e.bytes), action: { env.nav.open(container: e.id) }) {
                    HStack {
                        Text(e.name).font(.body).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Fmt.bytes(e.bytes)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .motion(Motion.standard, value: top.map(\.id))
        .motion(Motion.snappy, value: model.total)
    }
}
