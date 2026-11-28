import SwiftUI
import Darwin

if CommandLine.arguments.contains("--terminal-self-test") {
    exit(TerminalChecks.run())
}

if CommandLine.arguments.contains("--setup-self-test") {
    exit(SetupChecks.run())
}

if CommandLine.arguments.contains(where: { $0.hasPrefix("--welcome-self-test") }) {
    exit(WelcomeChecks.run())
}

if CommandLine.arguments.contains("--menubar-only") {
    MenuBarOnlyApp.main()
} else {
    NoodleApp.main()
}
