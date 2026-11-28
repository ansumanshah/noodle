import Testing
@testable import NoodleApp

@MainActor @Suite struct RouteShortcutTests {
    @Test func modesOwnTheRoutesAndTheirCommandKeys() {
        #expect(Route.Mode.allCases.map(\.shortcutKey) == ["1", "2", "3"])
        #expect(Route.Mode.models.routes == [.chat, .create, .library, .apps, .connections])
        #expect(Route.Mode.containers.routes == [.overview, .containers, .compose, .images, .volumes, .networks, .builds, .machines, .kubernetes])
        #expect(Route.Mode.runners.routes == [.runners, .runnerRepos, .runnerJobs, .runnerCaches])
        #expect(Route.Mode.runners.routes.map(\.title) == ["Overview", "Repos", "Jobs", "Caches"])
        #expect(Route.allCases == Route.Mode.allCases.flatMap(\.routes))
        #expect(Route.Mode.allCases.allSatisfy { $0.home.mode == $0 })
        #expect(NavigationModel().route == .chat)
    }

    @Test func switchingModeRestoresTheLastPageOfThatMode() {
        let nav = NavigationModel()
        nav.go(.route(.library))
        nav.switchMode(.containers)
        #expect(nav.route == .overview)
        nav.go(.route(.images))
        nav.switchMode(.runners)
        #expect(nav.route == .runners)
        nav.switchMode(.models)
        #expect(nav.route == .library)
        nav.switchMode(.containers)
        #expect(nav.route == .images)
        nav.go(.container("web"))
        #expect(nav.mode == .containers)
        nav.go(.route(.runners))
        #expect(nav.mode == .runners)
    }

    @Test func switchingModeKeepsTheSelection() {
        let nav = NavigationModel()
        nav.go(.container("web"))
        nav.switchMode(.models)
        nav.switchMode(.containers)
        #expect(nav.selectedContainers == ["web"])
        #expect(nav.detailContainer == "web")
        nav.selectedProject = "shop"
        nav.switchMode(.runners)
        nav.switchMode(.containers)
        #expect(nav.selectedProject == "shop")
    }

    @Test func arrowsWalkEveryRowOfTheModeAndStopAtTheEnds() {
        let ids = SidebarView.rowIDs(mode: .containers, projects: ["shop"])
        #expect(ids == ["overview", "containers", "compose", "project:shop", "images", "volumes", "networks", "builds", "machines", "kubernetes"])
        var seen = [ids[0]]
        while let last = seen.last, let next = SidebarView.row(after: last, in: ids, down: true), next != last {
            seen.append(next)
        }
        #expect(seen == ids)
        #expect(SidebarView.row(after: "overview", in: ids, down: false) == "overview")
        #expect(SidebarView.rowIDs(mode: .models, projects: ["shop"]) == ["chat", "create", "library", "apps", "connections"])
        #expect(SidebarView.rowIDs(mode: .runners, projects: ["shop"]) == ["runners", "runner-repos", "runner-jobs", "runner-caches"])
        #expect(Destination(arguments: ["Noodle", "--open-route=runner-jobs"]) == .route(.runnerJobs))
    }

    /// Marketing captures still pass `--open-route=models` with a tab; each lands on the row that replaced it.
    @Test func oldModelsFlagsMapToTheNewRows() {
        func open(_ args: [String]) -> Destination? { Destination(arguments: ["Noodle"] + args) }
        #expect(open(["--open-route=models"]) == .route(.chat))
        #expect(open(["--open-route=models", "--demo-models-tab=chat"]) == .route(.chat))
        #expect(open(["--open-route=models", "--demo-models-tab=library"]) == .route(.library))
        #expect(open(["--open-route=models", "--demo-models-tab=downloads"]) == .route(.library))
        #expect(open(["--open-route=models", "--demo-models-tab=connections"]) == .route(.connections))
        #expect(open(["--open-route=library"]) == .route(.library))
    }
}
