import Observation

enum MachinePlatform: Hashable { case linux, macOS }

@MainActor @Observable
final class NavigationModel {
    var route: Route = .chat { didSet { lastRoute[route.mode] = route } }
    /// The page each mode was last on, restored when its mode is picked again.
    private(set) var lastRoute: [Route.Mode: Route] = [:]
    var mode: Route.Mode { route.mode }
    var selectedProject: String?
    /// The machine shown in Machines, by name.
    var selectedMachine: String?
    var machinePlatform: MachinePlatform = .linux
    var selectedContainers: Set<String> = []
    var detailContainer: String?
    var tab: ContainerTab = .info
    var search = ""
    var showSetup = false
    /// The first-run welcome. Shown once (see WelcomeFlow.shouldShow); "Set Up Noodle…" opens the Docker assistant instead.
    var showWelcome = false
    var showUninstall = false
    var uninstallRunning = false
    var uninstallFinished = false
    var setupMutationRunning = false
    var installationBusy: Bool { setupMutationRunning || uninstallRunning }
    var canChangeInstallation: Bool { !installationBusy && !uninstallFinished }

    func requestSetup() {
        guard canChangeInstallation, !showUninstall else { return }
        showSetup = true
    }
    var showDockerDefault = false
    var confirmation: Confirmation?

    var showsMacMachine: Bool { route == .machines && machinePlatform == .macOS }

    /// Single selected container id, if exactly one.
    var focusedContainer: String? { selectedContainers.count == 1 ? selectedContainers.first : nil }

    /// Explicit destinations also clear a filter when the route itself stays the same.
    func open(_ destination: Destination) {
        search = ""
        go(destination)
    }

    func switchMode(_ mode: Route.Mode) {
        guard mode != route.mode else { return }
        search = ""
        route = lastRoute[mode] ?? mode.home // keeps the selection, unlike go(.route)
    }

    func open(container id: String) {
        route = .containers
        search = ""
        selectedProject = nil
        selectedContainers = [id]
        detailContainer = id
    }
}
