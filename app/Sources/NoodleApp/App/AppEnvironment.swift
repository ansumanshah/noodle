import Foundation
import Observation
import AppKit
import NoodleCore

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let paths = NoodlePaths.resolve()
    let service: any DockerService
    let demo: Bool
    let connection = ConnectionModel()
    let firstStart: FirstStartNotice
    let containers: ContainersModel
    let images: ResourceModel<ImageSummary>
    let volumes: ResourceModel<VolumeSummary>
    let networks: ResourceModel<NetworkSummary>
    let nav = NavigationModel()
    /// The repos Runners serves, read by the Runners page and the sidebar; reloaded after add and remove.
    let runnerRepos = RunnerRepoList()
    /// The Machines page store, here so Refresh can reach it.
    let machines = LinuxMachinesStore()
    lazy var macMachine = MacMachineStore(home: paths.root)
    /// Shared so the sidebar card reads the same cluster state the Kubernetes page polls.
    lazy var kubernetes = KubernetesStore()
    lazy var apps = AIAppsStore.live(env: self)
    lazy var compose = ComposeStore(containers: containers, compose: AIAppsStore.liveCompose(env: self))
    /// One store for every image's Security tab, so a running scan survives navigation and Clear cache stays guarded.
    let security = SecurityStore()
    private(set) var sync: SyncController!
    var openMain: (() -> Void)?

    private convenience init() {
        // NOODLE_DEMO=1 acts like --demo for the render tests, which cannot set the process arguments.
        let args = DemoFlags.arguments
        let demoMode: DemoDocker.Mode? = {
            if args.contains("--demo-down") { return .down }
            if args.contains("--demo-empty") { return .empty }
            if args.contains("--demo") { return .normal }
            return nil
        }()
        let svc: any DockerService = demoMode.map { DemoDocker(mode: $0) } ?? DockerAPI(path: NoodlePaths.resolve().socket.path)
        self.init(service: svc, demo: demoMode != nil)
        // A demo window shows a finished install, so the sidebar card is not covered by a setup prompt.
        if demoMode != nil && !args.contains("--demo-setup") { connection.setupDone = true; connection.setupCompleted = true }

        // `--flag=value` form: a bare value argument would be treated by AppKit as a file to open.
        if let v = Self.arg("--demo-page"), let r = Route(argument: v, modelsTab: Self.arg("--demo-models-tab")) {
            nav.route = r
        }
        // Demo capture: open a Compose project's detail, with `--demo-compose-down` also showing its Down sheet.
        if let v = Self.arg("--open-compose") { nav.route = .compose; nav.selectedProject = v }
        if let v = Self.arg("--demo-tab"), let t = ContainerTab(rawValue: v.capitalized) { nav.tab = t }
        // A destination handed over by the menu bar copy. Containers resolve later, once they load (see demoSelect).
        if let destination = Destination(arguments: args), !destination.isContainer { nav.open(destination) }
        if args.contains("--demo-setup") { nav.showSetup = true }
        if WelcomeSheet.scripted { nav.showWelcome = true }
        if !demo && !connection.setupDone { nav.showSetup = false } // shown only once the daemon is confirmed down
    }

    init(service: any DockerService, demo: Bool) {
        self.service = service
        self.demo = demo
        let notice = FirstStartNotice()
        firstStart = notice
        containers = ContainersModel(service: service) { name in
            if !demo { notice.show(name) }
        }
        images = ResourceModel(fetch: { try await service.images() }, delete: { try await service.removeImage($0) })
        volumes = ResourceModel(fetch: { try await service.volumes() }, delete: { try await service.removeVolume($0) })
        networks = ResourceModel(fetch: { try await service.networks() }, delete: { try await service.removeNetwork($0) })
        machines.configure(demo: demo)
        sync = SyncController(env: self)
    }

    var demoSelect: String? { Self.arg("--open-container") ?? Self.arg("--demo-select") }

    static func arg(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    func reloadVMSettings() {
        if !demo { connection.vmSettings = VMSettings.load(paths: paths) }
    }
}
