import Foundation

/// One Compose project as the containers' labels describe it. Nothing is stored: it is rebuilt on every refresh.
struct ComposeProjectInfo: Identifiable, Hashable, Sendable {
    var name: String
    /// `com.docker.compose.project.working_dir`; nil when the label is missing.
    var directory: String?
    /// `com.docker.compose.project.config_files`, in order.
    var configFiles: [String]
    var containers: [ContainerSummary]
    var id: String { name }
    var runningCount: Int { containers.filter(\.isRunning).count }
    var canRunFromFiles: Bool { !configFiles.isEmpty }
}

enum ComposeAction: Hashable, Sendable {
    case up, down(removeVolumes: Bool), restart, pull
}

enum ComposeProjects {
    /// Projects from container labels, sorted by name. Apps (`noodle-app-*`) belong to the Apps page.
    static func group(_ items: [ContainerSummary]) -> [ComposeProjectInfo] {
        var byName: [String: [ContainerSummary]] = [:]
        for c in items { if let p = c.project, !AIApp.isAppProject(p) { byName[p, default: []].append(c) } }
        return byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let members = byName[name] ?? []
            func label(_ key: String) -> String? {
                members.lazy.compactMap { $0.labels[key] }.first { !$0.isEmpty }
            }
            return ComposeProjectInfo(
                name: name, directory: label("com.docker.compose.project.working_dir"),
                configFiles: (label("com.docker.compose.project.config_files") ?? "")
                    .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                containers: members)
        }
    }

    /// Arguments after `docker compose`. Only Up and Pull read the folder and files. Each path is its own argument, so spaces need no quoting.
    static func arguments(_ action: ComposeAction, for project: ComposeProjectInfo) -> [String] {
        var args = ["--progress", "plain", "-p", project.name]
        // Down and Restart find the project by name, so they work after its folder or file moved.
        switch action {
        case .up, .pull:
            if let directory = project.directory { args += ["--project-directory", directory] }
            for file in project.configFiles { args += ["-f", file] }
        case .down, .restart: break
        }
        switch action {
        case .up: args += ["up", "-d"]
        case .down(let removeVolumes): args += ["down"] + (removeVolumes ? ["--volumes"] : [])
        case .restart: args += ["restart"]
        case .pull: args += ["pull"]
        }
        return args
    }
}
