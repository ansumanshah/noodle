import Foundation
import Observation
import AppKit

struct LinuxMachine: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    var state: String
    let distro: String
    let image: String
    let cpus: Int
    let memoryMiB: Int
    let diskGiB: Int
    var id: String { name }
    var isRunning: Bool { state == "running" }
}

@MainActor @Observable
final class LinuxMachinesStore {
    private(set) var items: [LinuxMachine] = []
    private(set) var loaded = false
    /// Advances only after a successful list, even when the items did not change.
    private(set) var listRevision = 0
    private(set) var busy = false
    /// "Stopping" and similar, by machine name, while a command runs.
    private(set) var pending: [String: String] = [:]
    private(set) var info: [String: LinuxMachineInfo] = [:]
    var error: String?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var demo = false
    @ObservationIgnored private var generation = 0
    private let run: @MainActor ([String], TimeInterval) async -> CLI.Result

    init(run: @escaping @MainActor ([String], TimeInterval) async -> CLI.Result = { await CLI.run($0, timeout: $1) }) {
        self.run = run
    }

    func configure(demo: Bool) {
        guard !configured else { return }
        configured = true
        self.demo = demo
        if demo {
            items = DemoFlags.empty ? [] : DemoLinuxMachines.items
            loaded = true
            listRevision += 1
        }
    }

    func refresh() async {
        guard !demo, !refreshing, !busy else { return }
        refreshing = true
        let generation = self.generation
        defer { refreshing = false; loaded = true }
        let result = await run(["machine", "list", "--json"], 10)
        guard !Task.isCancelled, generation == self.generation else { return }
        guard result.code == 0 else { error = result.output; return }
        do {
            items = try JSONDecoder().decode([LinuxMachine].self, from: Data(result.output.utf8))
            listRevision += 1
        }
        catch { self.error = "Could not read the machine list: \(error.localizedDescription)" }
    }

    /// A retained list cannot invalidate a destination supplied since it was read.
    func validatedSelection(_ selection: String?, after revision: Int) -> String? {
        guard listRevision > revision else { return selection }
        return items.contains { $0.id == selection } ? selection : items.first?.id
    }

    /// Refresh: the list, then the details of the selected machine, so disk use is current.
    func reload(selected name: String?) async {
        await refresh()
        if let machine = items.first(where: { $0.name == name }) { await loadInfo(for: machine) }
    }

    /// Address, shared folder and disk in use. Read when a machine is selected or changes state, never on a timer.
    func loadInfo(for machine: LinuxMachine) async {
        guard machine.state != "incomplete" else { info[machine.name] = nil; return }
        if demo { info[machine.name] = DemoLinuxMachines.info[machine.name]; return }
        let result = await run(["machine", "status", machine.name], 10)
        guard !Task.isCancelled, result.code == 0 else { return }
        info[machine.name] = LinuxMachineInfo.parse(result.output)
    }

    func perform(_ action: String, machine: LinuxMachine) async {
        guard !busy else { return }
        generation += 1
        busy = true
        error = nil
        let label = ["start": "Starting", "stop": "Stopping", "restart": "Restarting", "delete": "Deleting"][action]
        if let label { Motion.animate { pending[machine.name] = label } }
        if demo {
            try? await Task.sleep(for: .milliseconds(350))
            if action == "delete" { items.removeAll { $0.id == machine.id } }
            else if let index = items.firstIndex(where: { $0.id == machine.id }) {
                items[index].state = action == "stop" ? "stopped" : "running"
            }
            listRevision += 1
        } else {
            let args = ["machine", action, machine.name] + (action == "delete" ? ["--yes"] : [])
            let result = await run(args, 180)
            if result.code != 0 { error = result.output }
        }
        Motion.animate { pending[machine.name] = nil }
        busy = false
        await refresh()
    }

    func create(name: String, distro: String, image: String?, cpus: Int, memoryMiB: Int, diskGiB: Int) async -> Bool {
        guard !busy else { return false }
        generation += 1
        busy = true
        error = nil
        var succeeded = true
        if demo {
            guard !items.contains(where: { $0.name == name }) else {
                error = "A machine with this name already exists."
                busy = false
                return false
            }
            let reference = image ?? (distro == "alpine" ? "alpine:3.22" : "ubuntu:24.04")
            items.append(LinuxMachine(name: name, state: "running", distro: image == nil ? distro : "custom", image: reference,
                                      cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB))
            items.sort { $0.name < $1.name }
            listRevision += 1
        } else {
            let source = image.map { ["--image", $0] } ?? ["--distro", distro]
            let result = await run(["machine", "create", name] + source +
                                  ["--cpus", String(cpus), "--memory", "\(memoryMiB)M", "--disk", String(diskGiB)], 1200)
            succeeded = result.code == 0
            if !succeeded { error = result.output }
        }
        busy = false
        await refresh()
        return succeeded
    }

    func openShell(_ machine: LinuxMachine) {
        guard !demo, !busy, machine.state != "incomplete" else { return }
        do { try TerminalLauncher.open(machine: machine.name) }
        catch { self.error = error.localizedDescription }
    }
}

extension TerminalLauncher {
    /// Matches the container shell path: an executable .command document opened by Terminal.
    @MainActor static func open(machine: String) throws {
        guard let executable = CLI.locate() else {
            throw NSError(domain: "Noodle", code: 127, userInfo: [NSLocalizedDescriptionKey: "The noodle command line tool was not found."])
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-machine-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        /bin/rm -f -- "$0"
        export NOODLE_HOME=\(quote(AppEnvironment.shared.paths.root.path))
        clear
        exec \(quote(executable.path)) machine shell \(quote(machine))
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard NSWorkspace.shared.open(url) else {
                throw NSError(domain: "Noodle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open Terminal."])
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
