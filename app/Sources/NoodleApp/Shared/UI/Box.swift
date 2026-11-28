import SwiftUI

/// The shared opaque surface. Lists with padded rows supply zero outer padding.
struct Box: ViewModifier {
    var padding: CGFloat = Space.panel

    func body(content: Content) -> some View {
        content.cardSurface(padding: padding, tinted: false)
    }
}

extension View {
    func box(padding: CGFloat = Space.panel) -> some View { modifier(Box(padding: padding)) }
}
