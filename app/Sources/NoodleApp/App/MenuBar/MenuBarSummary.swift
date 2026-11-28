import Foundation

/// Everything the menu bar menu shows, worked out from data already in memory. Pure, so it is tested without a menu.
struct MenuBarSummary: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        /// Where the row opens: the project for a project, the container for a loose container.
        var destination: Destination
        /// Set when the item itself is a failing container.
        var failed = false
        /// A failing member of a project, shown on its own row below it.
        var failure: Failure?
    }
    struct Failure: Equatable { var text: String; var containerID: String }
    struct Port: Identifiable, Equatable {
        var endpoint: PortEndpoint
        var owner: String
        /// Non-web ports copy their address, because a browser cannot show them.
        var copies: Bool
        var number: Int { endpoint.port }
        var id: String { endpoint.id }
        var address: String { endpoint.address }
        var title: String { MenuBarSummary.clip("\(endpoint.shown)\(endpoint.isTCP ? "" : "/" + endpoint.proto) · \(owner)") }
    }
    struct Machine: Identifiable, Equatable {
        var name: String
        var running: Bool
        var id: String { name }
        var title: String { MenuBarSummary.clip("\(name) · \(running ? "running" : "stopped")") }
    }

    /// Lists show at most five rows, then Show All with the full count.
    static let limit = 5

    var items: [Item] = []
    var totalItems = 0
    var ports: [Port] = []
    var totalPorts = 0
    var machines: [Machine] = []
    var totalMachines = 0

    static func vmStats(_ vm: VMReadiness, cpuPercent: Int?) -> String {
        let cpu = (vm.usage?.cpus ?? vm.cpus).flatMap { $0 > 0 ? $0 : nil }.map { count in
            cpuPercent.map { "CPU \($0)% · \(count) vCPU" } ?? "\(count) vCPU"
        }
        let memory = vm.memoryLimitBytes.map { limit in
            let used = vm.usage?.memoryUsed.flatMap { Int(exactly: $0) }
            return used.map { "Memory \(Fmt.bytes($0)) / \(Fmt.bytes(limit))" } ?? "Memory limit \(Fmt.bytes(limit))"
        }
        return [cpu, memory].compactMap { $0 }.joined(separator: " · ")
    }

    static func make(containers: [ContainerSummary], machines: [LinuxMachine], isUp: Bool, names: LocalNameTable = LocalNameTable()) -> MenuBarSummary {
        let ready = machines.filter { $0.state != "incomplete" }.map { Machine(name: $0.name, running: $0.isRunning) }
        var summary = MenuBarSummary(machines: Array(ready.prefix(limit)), totalMachines: ready.count)
        guard isUp else { return summary }
        let all = projectItems(containers) + looseItems(containers)
        let failures = all.filter { $0.failed || $0.failure != nil }
        let healthy = all.filter { !$0.failed && $0.failure == nil }
        summary.items = Array((failures + healthy).prefix(limit))
        summary.totalItems = all.count
        let ports = portList(containers, names: names)
        summary.ports = Array(ports.prefix(limit))
        summary.totalPorts = ports.count
        return summary
    }

    // MARK: - Projects and containers

    private static func projectItems(_ containers: [ContainerSummary]) -> [Item] {
        let byProject = Dictionary(grouping: containers.filter { $0.project != nil }) { $0.project ?? "" }
        let items: [(failing: Bool, item: Item)] = byProject.compactMap { name, members in
            let running = members.filter(\.isRunning)
            let failed = OverviewProblems.failing(members).sorted { $0.name < $1.name }
            guard !running.isEmpty || !failed.isEmpty else { return nil }
            // The row names the member when one is failing, and counts them otherwise. Its wording is the Overview's.
            let failure = failed.first.map {
                Failure(text: clip(failed.count > 1 ? "\(failed.count) containers need attention" : OverviewProblems.message($0)), containerID: $0.id)
            }
            let item = Item(id: "project:" + name, title: clip("\(name) · \(running.count) of \(members.count)"),
                            destination: .project(name), failure: failure)
            return (!failed.isEmpty, item)
        }
        return items.sorted { ($0.failing ? 0 : 1, $0.item.title) < ($1.failing ? 0 : 1, $1.item.title) }.map(\.item)
    }

    private static func looseItems(_ containers: [ContainerSummary]) -> [Item] {
        let failing = Set(OverviewProblems.failing(containers).map(\.id))
        return containers.filter { $0.project == nil && ($0.isRunning || failing.contains($0.id)) }
            .sorted { (failing.contains($0.id) ? 0 : 1, $0.name) < (failing.contains($1.id) ? 0 : 1, $1.name) }
            .map { c in
                let bad = failing.contains(c.id)
                return Item(id: "container:" + c.id, title: clip(bad ? OverviewProblems.message(c) : c.name),
                            destination: .container(c.id), failed: bad)
            }
    }

    // MARK: - Ports

    private static func portList(_ containers: [ContainerSummary], names: LocalNameTable) -> [Port] {
        var seen = Set<String>()
        var out: [Port] = []
        for container in containers where container.state == "running" {
            for endpoint in PortEndpoint.list(container, names: names) {
                guard seen.insert(endpoint.id).inserted else { continue }
                out.append(Port(endpoint: endpoint, owner: container.service ?? container.name,
                                copies: PortKind.of(endpoint, image: container.image) != .web))
            }
        }
        return out.sorted {
            ($0.number, $0.endpoint.isTCP ? 0 : 1, $0.endpoint.host, $0.endpoint.proto)
                < ($1.number, $1.endpoint.isTCP ? 0 : 1, $1.endpoint.host, $1.endpoint.proto)
        }
    }

    /// Menu rows stay under 30 characters.
    static func clip(_ text: String, limit: Int = 30) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
