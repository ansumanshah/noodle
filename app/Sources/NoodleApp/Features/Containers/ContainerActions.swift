import SwiftUI

@MainActor
enum ContainerActions {
    static func confirmRemove(env: AppEnvironment, ids: [String]) {
        let names = ids.compactMap { env.containers.container($0)?.name }
        guard !names.isEmpty else { return }
        let title = names.count == 1 ? String(localized: "Delete “\(names[0])”?") : String(localized: "Delete \(names.count) containers?")
        env.nav.confirmation = Confirmation(title: title, message: String(localized: "Running containers are stopped first. Their writable layers are removed. Volumes are kept."),
                                            confirmLabel: String(localized: "Delete")) {
            await env.containers.perform(.remove, ids: ids)
            env.nav.selectedContainers.subtract(ids)
        }
    }
    static func confirmRemoveProject(env: AppEnvironment, project: String) {
        env.nav.confirmation = Confirmation(title: String(localized: "Delete project “\(project)”?"), message: String(localized: "All containers in this Compose project are removed. Volumes and images are kept."),
                                            confirmLabel: String(localized: "Delete Project")) {
            let ids = env.containers.items.filter { $0.project == project }.map(\.id)
            await env.containers.perform(.remove, project: project)
            env.nav.selectedContainers.subtract(ids)
        }
    }
    static func openInTerminal(env: AppEnvironment, id: String) {
        guard let c = env.containers.container(id), c.isRunning else { return }
        guard let workspace = TerminalWindows.current else {
            env.connection.message = String(localized: "Open a Noodle window to use the embedded terminal.")
            return
        }
        workspace.open(container: c)
    }
    static func openInBrowser(env: AppEnvironment, id: String) {
        if let url = env.containers.container(id)?.openablePorts.first?.url { NSWorkspace.shared.open(url) }
    }
}
