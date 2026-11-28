import SwiftUI

/// The bottom bar. Back or skip on the left, the default button on the far right, on every page.
/// Return runs the default button and Esc runs the left one. On the finished page Esc closes the assistant.
struct SetupButtons: View {
    let flow: SetupFlow
    let close: (_ finished: Bool) -> Void

    var body: some View {
        HStack {
            if flow.stage == .done {
                // Esc closes the finished assistant. Done on the right is the visible way.
                Button("Close") { close(true) }
                    .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0).accessibilityHidden(true)
            } else {
                Button(left.title, action: left.action)
                    .keyboardShortcut(.cancelAction).disabled(left.disabled)
            }
            Spacer()
            Button(right.title, action: right.action)
                .keyboardShortcut(.defaultAction).buttonStyle(.primaryAction).disabled(right.disabled)
        }
        .buttonStyle(.neutralAction)
        .motion(Motion.snappy, value: right.title)
    }

    private struct Item { var title: String; var disabled = false; var action: () -> Void }

    private var left: Item {
        switch flow.stage {
        case .detect, .plan: Item(title: String(localized: "Not Now")) { flow.stopWork(); close(false) }
        // Download, import and the pull stop cleanly and say what remains. Applying the choices is never cut short.
        case .download, .importing: Item(title: String(localized: "Cancel"), disabled: flow.stopping) { flow.stopWork() }
        case .container where flow.cancellable: Item(title: String(localized: "Cancel"), disabled: flow.stopping) { flow.stopWork() }
        case .install, .container: Item(title: String(localized: "Skip for Now")) { flow.abandon(); close(false) }
        case .failed where flow.failedFrom == .importing: Item(title: String(localized: "Skip for Now")) { flow.skipImport() }
        case .failed: Item(title: String(localized: "Skip for Now")) { close(false) }
        case .engine where flow.toolsSkipped: Item(title: String(localized: "Not Now")) { close(false) }
        case .engine, .importChoice: Item(title: String(localized: "Go Back")) { flow.goBack() }
        case .done: Item(title: String(localized: "Done")) { close(true) }
        }
    }

    private var right: Item {
        if flow.stopping { return Item(title: String(localized: "Stopping…"), disabled: true) {} }
        return switch flow.stage {
        case .detect: Item(title: String(localized: "Continue"), disabled: true) {}
        case .plan: Item(title: String(localized: "Continue")) { flow.continueFromTools() }
        case .download: Item(title: String(localized: "Downloading…"), disabled: true) {}
        case .engine: Item(title: String(localized: "Continue")) { flow.continueFromEngine() }
        case .importChoice:
            Item(title: flow.importOn ? "Import and Continue" : "Continue", disabled: flow.importOn && flow.importFlags.isEmpty) {
                flow.continueFromImport()
            }
        case .install, .importing, .container: Item(title: String(localized: "Setting Up…"), disabled: true) {}
        case .done: Item(title: String(localized: "Done")) { close(true) }
        case .failed: Item(title: String(localized: "Try Again")) { flow.retry() }
        }
    }
}
