import Foundation

/// Demo switches, read from the process arguments and from `NOODLE_DEMO` for runs that cannot set arguments
/// (render tests). `NOODLE_DEMO=1` acts like `--demo`, `empty` adds `--demo-empty`, `down` adds `--demo-down`.
enum DemoFlags {
    /// Computed, not cached: render tests set `NOODLE_DEMO` after other suites may already have read the flags.
    static var arguments: [String] {
        let extra: [String] = switch ProcessInfo.processInfo.environment["NOODLE_DEMO"] {
        case "1": ["--demo"]
        case "empty": ["--demo", "--demo-empty"]
        case "down": ["--demo", "--demo-down"]
        default: []
        }
        return CommandLine.arguments + extra
    }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }
    static var empty: Bool { has("--demo-empty") }
    /// `--demo-healthy`: every shop container runs and logs carry no errors, for site captures. The default demo keeps a failure to show problems.
    static var healthy: Bool { has("--demo-healthy") }
}

extension DemoFlags {
    /// Demo-only Models fixtures for headless captures: `--demo-models=<state>` and `--demo-models-tab=<row>`.
    static func value(_ prefix: String) -> String? {
        arguments.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var modelsState: ModelsPageStore.DemoState? {
        switch value("--demo-models=") {
        case "available": .available
        case "installed": .installed
        case "downloading": .downloading
        case "verifying": .verifying
        case "starting": .starting
        case "running": .running
        case "receiving": .receiving
        case "failed": .failed
        case "mlx-running": .mlxRunning
        case "mlx-receiving": .mlxReceiving
        case "streaming": .streaming
        default: nil
        }
    }

    /// `--demo-models-tab=` names a Models row (see `Route(argument:modelsTab:)`). Downloads became Library's
    /// Downloading filter, so that old value also picks the filter.
    static var libraryFilter: ModelLibraryFilter? { value("--demo-models-tab=") == "downloads" ? .downloading : nil }

    /// `--demo-sidebar=hidden` starts demo captures with the sidebar collapsed.
    static var sidebarHidden: Bool { value("--demo-sidebar=") == "hidden" }
    /// `--demo-reveal-row=shop` shows that Overview row in its hovered state, which a hidden capture window cannot produce.
    static let revealRow = value("--demo-reveal-row=")
    /// `--demo-size=680x460`: the capture window's size, for checking narrow layouts. Default size when absent.
    static var windowSize: CGSize {
        let parts = (value("--demo-size=") ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : WorkspaceStyle.defaultWindowSize
    }
}
