import AppKit
import Foundation

/// Draws every welcome state in light and dark with no window on screen.
/// Run with: NOODLE_NO_ACTIVATE=1 NoodleApp --welcome-self-test [--welcome-self-test-out=<dir>]
@MainActor
enum WelcomeChecks {
    static func run() -> Int32 {
        _ = NSApplication.shared
        do {
            try renderStates(out: AppEnvironment.arg("--welcome-self-test-out"))
            print("PASS welcome-render-states")
            return 0
        } catch {
            FileHandle.standardError.write(Data("FAIL welcome-self-test: \(error)\n".utf8))
            return 1
        }
    }

    static func renderStates(out: String?) throws {
        if let out { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }
        for name in WelcomePreview.names {
            for dark in [false, true] {
                guard let flow = WelcomePreview.flow(named: name) else { throw SetupChecks.Failure(description: "No preview \(name)") }
                guard let rep = SetupChecks.render(WelcomeSheetContent(flow: flow, close: {}), dark: dark) else {
                    throw SetupChecks.Failure(description: "Cannot render \(name)")
                }
                try SetupChecks.expect(SetupChecks.distinctColors(rep) > 4, "Welcome state \(name) rendered blank")
                if let out, let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: out + "/welcome-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
