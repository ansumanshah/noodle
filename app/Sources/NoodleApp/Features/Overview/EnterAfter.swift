import SwiftUI
import AppKit

/// Content fades in a beat after its container starts moving. Reduce Motion keeps a short fade.
struct EnterAfter: ViewModifier {
    var delay = 0.1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
            .animation(reduceMotion ? Motion.reduced : Motion.snappy.delay(delay), value: shown)
            .onAppear { shown = true }
    }
}
