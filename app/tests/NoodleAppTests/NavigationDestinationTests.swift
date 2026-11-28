import Testing
@testable import NoodleApp

@MainActor @Suite struct NavigationDestinationTests {
    @Test func argumentsRoundTrip() {
        let all: [Destination] = [.container("abc"), .project("shop"), .machine("alpine-test"), .macMachine, .route(.machines)]
        for destination in all { #expect(Destination(arguments: ["Noodle"] + destination.arguments) == destination) }
    }

    @Test func noArgumentMeansNoDestination() {
        #expect(Destination(arguments: ["Noodle", "--demo"]) == nil)
        #expect(Destination(arguments: ["--open-route=nowhere"]) == nil)
        #expect(Destination(arguments: ["--open-project="]) == nil)
    }

    @Test func projectKeepsTheFilterInsteadOfOpeningAMember() {
        let nav = NavigationModel()
        nav.open(container: "x")
        nav.go(.project("shop"))
        #expect(nav.route == .containers && nav.selectedProject == "shop")
        #expect(nav.detailContainer == nil && nav.selectedContainers.isEmpty)
    }

    @Test func namedMachineIsSelectedOnTheMachinesPage() {
        let nav = NavigationModel()
        nav.go(.macMachine)
        #expect(nav.route == .machines && nav.machinePlatform == .macOS)
        nav.go(.machine("alpine-test"))
        #expect(nav.route == .machines && nav.selectedMachine == "alpine-test" && nav.machinePlatform == .linux)
    }

    @Test func routeClearsProjectAndContainer() {
        let nav = NavigationModel()
        nav.go(.project("shop"))
        nav.go(.route(.machines))
        #expect(nav.route == .machines && nav.selectedProject == nil)
        nav.open(container: "x")
        nav.go(.route(.containers))
        #expect(nav.selectedProject == nil && nav.detailContainer == nil)
    }

    @Test func explicitDestinationClearsSearchEvenOnTheSamePage() {
        let nav = NavigationModel()
        nav.route = .containers
        nav.search = "unrelated"
        nav.open(.project("shop"))
        #expect(nav.selectedProject == "shop" && nav.search.isEmpty)
        nav.search = "unrelated"
        nav.open(.route(.containers))
        #expect(nav.selectedProject == nil && nav.search.isEmpty)
        nav.route = .machines
        nav.search = "dev"
        nav.open(.machine("alpine-test"))
        #expect(nav.selectedMachine == "alpine-test" && nav.search.isEmpty)
    }

    @Test func failureDestinationClearsTheProjectFilter() {
        let nav = NavigationModel()
        nav.open(.project("shop"))
        nav.open(.container("failed-worker"))
        #expect(nav.route == .containers && nav.selectedProject == nil)
        #expect(nav.detailContainer == "failed-worker" && nav.selectedContainers == ["failed-worker"])
    }

    @Test func relaunchReplacesOldDestinationsAndKeepsUnrelatedArguments() {
        let original = ["Noodle", "--menubar-only", "--demo", "--open-container=old", "--open-project=old",
                        "--open-machine=old", "--open-macos-machine", "--open-route=images", "--demo-select=old", "--demo-page=images",
                        "--demo-tab=logs", "--demo-setup"]
        let cases: [(Destination, String)] = [(.project("shop"), "--open-project=shop"),
                                             (.machine("alpine-test"), "--open-machine=alpine-test"),
                                             (.macMachine, "--open-macos-machine"),
                                             (.container("failed-worker"), "--open-container=failed-worker"),
                                             (.route(.containers), "--open-route=containers"),
                                             (.route(.machines), "--open-route=machines")]
        for (destination, argument) in cases {
            let args = Relaunch.arguments(from: original, menuBarOnly: false, open: destination)
            #expect(args == ["--demo", argument])
            let parsed = Destination(arguments: ["Noodle"] + args)
            #expect(parsed == destination)
        }
        #expect(Relaunch.arguments(from: original, menuBarOnly: true) == ["--demo", "--menubar-only"])
        // Closing the window hands the page to the menu bar copy, which hands it back on reopen.
        let menuBar = Relaunch.arguments(from: original, menuBarOnly: true, open: .route(.images))
        #expect(menuBar == ["--demo", "--menubar-only", "--open-route=images"])
        #expect(Destination(arguments: ["Noodle"] + menuBar) == .route(.images))
    }
}
