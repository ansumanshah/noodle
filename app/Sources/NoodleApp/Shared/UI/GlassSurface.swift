import SwiftUI

/// The one glass sheen for controls and cards: a mostly opaque base with a faint tinted highlight from the top edge, so
/// it reads as glass without showing what is behind. Reduce Transparency keeps a solid base. Not for list rows, tables
/// or the terminal.
// shortcut: a drawn sheen, not `glassEffect`; that painted over the content of cards in headless renders. Swap when it can be verified.
private struct GlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let base = Color(nsColor: .windowBackgroundColor)
        content.background {
            if reduceTransparency {
                shape.fill(base)
            } else {
                shape.fill(base.opacity(0.92))
                    .overlay {
                        shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.04 : 0.3),
                                                           tint.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    }
            }
        }
    }
}

extension View {
    func glassSurface(radius: CGFloat = Control.radius, tint: Color = .primary) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint))
    }
}
