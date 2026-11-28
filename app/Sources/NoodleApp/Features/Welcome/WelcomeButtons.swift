import SwiftUI

/// A round Back and a capsule Continue, centred. Return runs Continue; Esc closes the welcome on any screen.
struct WelcomeButtons: View {
    let flow: WelcomeFlow
    let close: () -> Void

    var body: some View {
        let first = flow.screen == .choose
        HStack(spacing: Control.gap) {
            Button { flow.back() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.roundIconAction).help("Back")
                .opacity(first ? 0 : 1).disabled(first).accessibilityHidden(first)
            Button { flow.screen == .done ? close() : flow.next() } label: {
                Text(flow.screen == .done ? "Open Noodle" : "Continue").padding(.horizontal, Space.xl).contentTransition(.opacity)
            }
            .buttonStyle(.capsuleAction).keyboardShortcut(.defaultAction).disabled(!flow.canContinue)
            // Balances Back, so Continue stays in the centre.
            Color.clear.frame(width: Control.height, height: Control.height).accessibilityHidden(true)
        }
        .background {
            Button("Close") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
        .motion(Motion.snappy, value: flow.screen)
        .motion(Motion.snappy, value: flow.canContinue)
    }
}
