import SwiftUI
import AppKit

/// motion-first tokens as SwiftUI springs.
enum Motion {
    static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.84)
    static let standard = Animation.spring(response: 0.48, dampingFraction: 1.0)
    static let heavy = Animation.spring(response: 0.66, dampingFraction: 1.0)
    /// Reduce Motion keeps feedback but swaps springs for a short fade.
    static let reduced = Animation.easeOut(duration: 0.12)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let token: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduce ? Motion.reduced : token, value: value)
    }
}

extension View {
    func motion<V: Equatable>(_ token: Animation = Motion.snappy, value: V) -> some View {
        modifier(MotionModifier(token: token, value: value))
    }
}

extension AnyTransition {
    static var row: AnyTransition { .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)) }
    /// Fades in over a short rise from an edge; with Reduce Motion it only fades. A panel never travels its own
    /// width or height: a full-length slide reads as the page jumping.
    @MainActor static func slide(from edge: Edge) -> AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        let d: CGFloat = 8
        let offset: CGSize = switch edge {
        case .top: CGSize(width: 0, height: -d)
        case .bottom: CGSize(width: 0, height: d)
        case .leading: CGSize(width: -d, height: 0)
        case .trailing: CGSize(width: d, height: 0)
        }
        return .offset(offset).combined(with: .opacity)
    }
}

extension Motion {
    /// Wraps a state mutation in the right animation for the current Reduce Motion setting.
    @MainActor static func animate(_ token: Animation = Motion.snappy, _ body: () -> Void) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? reduced : token, body)
    }
}
