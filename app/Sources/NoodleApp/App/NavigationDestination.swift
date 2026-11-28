import Foundation

/// Where Noodle should open. Carried by the menu bar and the Overview, and by launch arguments when the menu bar
/// copy hands over to the full app, so a choice survives the relaunch.
enum Destination: Equatable {
    case container(String)
    case project(String)
    case machine(String)
    case macMachine
    case route(Route)

    /// Launch arguments in the `--flag=value` form: a bare value would be treated by AppKit as a file to open.
    var arguments: [String] {
        switch self {
        case .container(let id): ["--open-container=\(id)"]
        case .project(let name): ["--open-project=\(name)"]
        case .machine(let name): ["--open-machine=\(name)"]
        case .macMachine: ["--open-macos-machine"]
        case .route(let route): ["--open-route=\(route.rawValue)"]
        }
    }

    var isContainer: Bool { if case .container = self { true } else { false } }

    /// Argument prefixes a relaunch replaces.
    static let argumentPrefixes = ["--open-container=", "--open-project=", "--open-machine=", "--open-macos-machine", "--open-route="]

    /// The destination named by launch arguments, if any. Container names resolve later, once containers load.
    init?(arguments: [String]) {
        func value(_ prefix: String) -> String? {
            arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let name = value("--open-project=") { self = .project(name) }
        else if let name = value("--open-machine=") { self = .machine(name) }
        else if let raw = value("--open-route="),
                let route = Route(argument: raw, modelsTab: value("--demo-models-tab=")) { self = .route(route) }
        else if arguments.contains("--open-macos-machine") { self = .macMachine }
        else if let id = value("--open-container=") { self = .container(id) }
        else { return nil }
    }
}

extension NavigationModel {
    func go(_ destination: Destination) {
        switch destination {
        case .container(let id): open(container: id)
        case .project(let name):
            route = .containers
            selectedProject = name
            selectedContainers = []
            detailContainer = nil
        case .machine(let name):
            route = .machines
            machinePlatform = .linux
            selectedMachine = name
        case .macMachine:
            route = .machines
            machinePlatform = .macOS
        case .route(let target):
            route = target
            selectedProject = nil
            selectedContainers = []
            detailContainer = nil
        }
    }
}
