import Foundation
import Observation
import SwiftUI
import NoodleCore

// One observable per feature. Rows get value types, never these objects.

@MainActor @Observable
final class ConnectionModel {
    enum Phase: Equatable { case connecting, up, down(String) }
    enum Transition: Equatable { case starting, stopping }
    var phase: Phase = .connecting
    var info: DaemonInfo?
    var vmReadiness: VMReadiness?
    var vmCPUPercent: Int?
    var vmSettings = VMSettings.defaults()
    var dockerTarget: String?
    /// The engine can run while Docker has no `noodle` context, and then `docker --context noodle` fails.
    var noodleContextMissing = false
    /// Plain `docker` goes to another engine, so what a terminal starts never shows up in this window.
    var dockerElsewhere = false
    var reconnecting = false
    var retryingConnection = false
    var transition: Transition?
    var setupDone: Bool = CLI.isSetUp
    /// Existing installs without an assistant receipt stay quiet. A skipped assistant stays easy to reopen.
    var setupCompleted: Bool? = UserDefaults.standard.object(forKey: "setupCompleted") as? Bool
    var needsSetup: Bool { !setupDone || setupCompleted == false }
    var message: String?

    var isUp: Bool { phase == .up }
}

@MainActor @Observable
final class ContainersModel {
    private(set) var items: [ContainerSummary] = []
    private(set) var groups: [ContainerGroup] = []
    private(set) var names = LocalNameTable()
    private(set) var loaded = false
    private(set) var pending: [String: String] = [:]
    var actionError: String?
    var runningCount: Int { items.lazy.filter(\.isRunning).count }
    let service: any DockerService
    private let didStart: (@MainActor (String) -> Void)?

    init(service: any DockerService, didStart: (@MainActor (String) -> Void)? = nil) {
        self.service = service
        self.didStart = didStart
    }

    /// Names ride on the container refresh: no timer of their own.
    func refresh() async throws {
        async let table = try? service.localNames()
        let list = try await service.containers()
        let fresh = await table ?? LocalNameTable()
        if fresh != names { names = fresh }
        apply(list)
    }

    func apply(_ new: [ContainerSummary]) {
        let sorted = new.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard sorted != items || !loaded else { return }
        Motion.animate(Motion.snappy) {
            items = sorted
            groups = Self.group(sorted)
            loaded = true
        }
    }

    static func group(_ items: [ContainerSummary]) -> [ContainerGroup] {
        var byProject: [String: [ContainerSummary]] = [:]
        var loose: [ContainerSummary] = []
        for c in items { if let p = c.project { byProject[p, default: []].append(c) } else { loose.append(c) } }
        var out = byProject.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ContainerGroup(project: $0, containers: byProject[$0]!) }
        if !loose.isEmpty { out.append(ContainerGroup(project: nil, containers: loose)) }
        return out
    }

    func container(_ id: String?) -> ContainerSummary? { id.flatMap { id in items.first { $0.id == id } } }

    enum Action: String {
        case start = "Starting", stop = "Stopping", restart = "Restarting", remove = "Removing"
        var label: String {
            switch self {
            case .start: String(localized: "Starting")
            case .stop: String(localized: "Stopping")
            case .restart: String(localized: "Restarting")
            case .remove: String(localized: "Removing")
            }
        }
    }

    func perform(_ action: Action, ids: [String]) async {
        let ids = ids.filter { pending[$0] == nil }
        guard !ids.isEmpty else { return }
        Motion.animate { for id in ids { pending[id] = action.label } }
        let svc = service
        await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        switch action {
                        case .start: try await svc.start(id)
                        case .stop: try await svc.stop(id)
                        case .restart: try await svc.restart(id)
                        case .remove: try await svc.removeContainer(id)
                        }
                        return (id, nil)
                    } catch { return (id, error.localizedDescription) }
                }
            }
            for await (id, err) in group {
                if let err { actionError = err }
                else if action == .start, let name = container(id)?.name { didStart?(name) }
            }
        }
        try? await refresh()
        Motion.animate { for id in ids { pending[id] = nil } }
    }

    func perform(_ action: Action, project: String) async {
        let members = items.filter { $0.project == project }
        guard !members.isEmpty, members.allSatisfy({ pending[$0.id] == nil }) else { return }
        let ordered: [ContainerSummary]
        do { ordered = try ComposeProject.startOrder(members) }
        catch { actionError = error.localizedDescription; return }

        // Reserve the entire project before suspending, including already-running dependencies.
        // Row, menu bar and other project actions must not race this operation.
        actionError = nil
        Motion.animate { for container in members { pending[container.id] = action.rawValue } }
        do {
            switch action {
            case .start:
                for container in ordered where !container.isRunning {
                    try await service.start(container.id)
                    didStart?(container.name)
                }
            case .stop:
                for container in ordered.reversed() where container.isRunning { try await service.stop(container.id) }
            case .restart:
                for container in ordered.reversed() where container.isRunning { try await service.stop(container.id) }
                for container in ordered { try await service.start(container.id) }
            case .remove:
                for container in ordered.reversed() {
                    if container.isRunning { try await service.stop(container.id) }
                    try await service.removeContainer(container.id)
                }
            }
        } catch {
            actionError = "\(action.rawValue) project “\(project)”: \(error.localizedDescription)"
        }
        do { try await refresh() }
        catch { actionError = actionError ?? "Could not refresh project “\(project)”: \(error.localizedDescription)" }
        Motion.animate { for container in members { pending[container.id] = nil } }
    }
}

@MainActor @Observable
final class ResourceModel<Item: Identifiable & Hashable & Sendable> where Item.ID: Sendable {
    private(set) var items: [Item] = []
    private(set) var loaded = false
    var actionError: String?
    private let fetch: @Sendable () async throws -> [Item]
    private let delete: @Sendable (Item.ID) async throws -> Void

    init(fetch: @escaping @Sendable () async throws -> [Item], delete: @escaping @Sendable (Item.ID) async throws -> Void) {
        self.fetch = fetch; self.delete = delete
    }

    func refresh() async throws { apply(try await fetch()) }
    func apply(_ new: [Item]) {
        guard new != items || !loaded else { return }
        Motion.animate { items = new; loaded = true }
    }
    func remove(_ ids: [Item.ID]) async {
        for id in ids {
            do { try await delete(id) } catch { actionError = error.localizedDescription }
        }
        try? await refresh()
    }
}

enum Route: String, CaseIterable, Identifiable, Hashable {
    // Order: Models pages, then Containers pages, then Runners.
    case chat, create, library, apps, connections
    case overview, containers, compose, images, volumes, networks, builds, machines, kubernetes
    // `runners` is the Runners Overview; its raw value stays so `--open-route=runners` still opens it.
    case runners, runnerRepos = "runner-repos", runnerJobs = "runner-jobs", runnerCaches = "runner-caches"
    var id: String { rawValue }

    /// The three products. The header switcher picks one; the sidebar lists only its pages.
    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case models, containers, runners
        var id: String { rawValue }

        var title: String {
            switch self {
            case .models: String(localized: "Models")
            case .containers: String(localized: "Containers")
            case .runners: String(localized: "Runners")
            }
        }
        var symbol: String {
            switch self { case .models: "sparkles"; case .containers: "shippingbox"; case .runners: "play.circle" }
        }
        var tone: WorkspaceStyle.Tone {
            switch self { case .models: WorkspaceStyle.models; case .containers: WorkspaceStyle.containers; case .runners: WorkspaceStyle.runners }
        }
        /// The pages this mode's sidebar lists, in order.
        var routes: [Route] { Route.allCases.filter { $0.mode == self } }
        /// Where a mode opens the first time.
        var home: Route { switch self { case .models: .chat; case .containers: .overview; case .runners: .runners } }
        /// Command-1 to Command-3.
        var shortcutKey: KeyEquivalent { switch self { case .models: "1"; case .containers: "2"; case .runners: "3" } }
    }

    var isModels: Bool { mode == .models }

    var mode: Mode {
        switch self {
        case .chat, .create, .library, .apps, .connections: .models
        case .runners, .runnerRepos, .runnerJobs, .runnerCaches: .runners
        default: .containers
        }
    }

    /// A route named in `--open-route=` or `--demo-page=`. `models` is the page before Chat, Library and Connections
    /// became rows; with `--demo-models-tab=` it still lands on the row that replaced the tab.
    init?(argument: String, modelsTab: String? = nil) {
        guard argument == "models" else { self.init(rawValue: argument); return }
        switch modelsTab {
        case "library", "downloads": self = .library
        case "connections": self = .connections
        default: self = .chat
        }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .containers: String(localized: "Containers")
        case .compose: String(localized: "Compose")
        case .images: String(localized: "Images")
        case .volumes: String(localized: "Volumes")
        case .networks: String(localized: "Networks")
        case .machines: String(localized: "Machines")
        case .kubernetes: String(localized: "Kubernetes")
        case .builds: String(localized: "Builds")
        case .runners: String(localized: "Overview")
        case .runnerRepos: String(localized: "Repos")
        case .runnerJobs: String(localized: "Jobs")
        case .runnerCaches: String(localized: "Caches")
        case .chat: String(localized: "Chat")
        case .create: String(localized: "Create")
        case .library: String(localized: "Library")
        case .connections: String(localized: "Connections")
        case .apps: String(localized: "Apps")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .containers: "shippingbox"; case .compose: "square.stack.3d.down.right"; case .images: "square.3.layers.3d"; case .volumes: "externaldrive"
        case .networks: "network"; case .machines: "server.rack"; case .kubernetes: "helm"
        case .builds: "hammer"
        case .runners: "play.circle"
        case .runnerRepos: "arrow.triangle.branch"
        case .runnerJobs: "list.bullet.rectangle"
        case .runnerCaches: "internaldrive"
        case .chat: "bubble.left.and.bubble.right"
        case .create: "wand.and.stars"
        case .library: "square.stack.3d.up"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .apps: "square.grid.3x3"
        }
    }

    /// The docs page an empty page links to.
    var docsURL: URL? {
        let path: String? = switch self {
        case .overview, .containers, .compose, .volumes, .kubernetes: "containers/quickstart"
        case .images, .builds: "containers/images"
        case .networks: "containers/networking"
        case .machines: "containers/machines"
        case .chat, .create, .apps: "models/quickstart"
        case .library: "models/catalog"
        case .connections: "models/api"
        case .runners, .runnerRepos, .runnerJobs, .runnerCaches: nil
        }
        // Link the Markdown source on GitHub, which tracks main.
        return path.flatMap { URL(string: "https://github.com/ansumanshah/noodle/blob/main/website/content/docs/" + $0 + ".mdx") }
    }
}

enum ContainerTab: String, CaseIterable, Identifiable {
    case info = "Info", logs = "Logs", run = "Run", files = "Files", stats = "Stats"
    var id: String { rawValue }
    /// The tab label. `rawValue` stays the English identifier.
    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .logs: String(localized: "Logs")
        case .run: String(localized: "Run")
        case .files: String(localized: "Files")
        case .stats: String(localized: "Stats")
        }
    }
    var symbol: String {
        switch self { case .info: "info.circle"; case .logs: "text.alignleft"; case .run: "terminal"; case .files: "folder"; case .stats: "chart.xyaxis.line" }
    }
}

struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var action: @MainActor () async -> Void
}
