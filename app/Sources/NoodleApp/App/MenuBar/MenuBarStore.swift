import Foundation
import AppKit
import Observation

/// Menu bar data that the window stores do not hold. Everything is read when the menu opens: no timer, no polling.
@MainActor @Observable
final class MenuBarStore {
    static let shared = MenuBarStore()
    private(set) var machines: [LinuxMachine] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastRefresh = Date.distantPast

    /// Containers, VM resources and the machine list, once per opening.
    func refresh(env: AppEnvironment) async {
        guard !refreshing, Date().timeIntervalSince(lastRefresh) > 1, env.connection.transition == nil else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = Date() }
        async let list = loadMachines(demo: env.demo)
        do {
            try await env.service.ping()
            async let readiness: Void = env.sync.refreshVMReadiness()
            try await env.containers.refresh()
            if !env.connection.isUp { env.connection.phase = .up }
            await readiness
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if env.connection.isUp || env.connection.phase == .connecting { env.connection.phase = .down(text) }
        }
        let fresh = await list
        if fresh != machines { machines = fresh }
    }

    private func loadMachines(demo: Bool) async -> [LinuxMachine] {
        if demo { return DemoFlags.empty ? [] : DemoLinuxMachines.items }
        let result = await CLI.run(["machine", "list", "--json"], timeout: 5)
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode([LinuxMachine].self, from: data) else { return machines }
        return list
    }

    /// Watches for the menu bar menu opening. Idle between openings.
    func watchOpenings(env: AppEnvironment) async {
        for await note in NotificationCenter.default.notifications(named: NSMenu.didBeginTrackingNotification) {
            let menu = note.object as? NSMenu
            guard Relaunch.isMenuBarOnly || menu?.items.contains(where: { $0.title == "Open Noodle" }) == true else { continue }
            await refresh(env: env)
        }
    }
}
