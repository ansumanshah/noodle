import SwiftUI

/// Chat-only metrics (the chat keeps its own bubble, composer and gutter sizes, not the control tokens) for the Models workspace; shared tokens live in DesignSystem.swift.
/// Layout numbers: 14 pt bubble padding and radius, 36 pt composer row, 18 pt composer radius.
enum ModelsChrome {
    /// Reading measure for prose, the composer and the empty-state greeting.
    static let readingWidth: CGFloat = 760
    static let gutter: CGFloat = 20
    static let bubblePaddingH: CGFloat = 14
    static let bubblePaddingV: CGFloat = 10
    static let bubbleRadius: CGFloat = 14
    static let composerRadius: CGFloat = 18
    static let composerControl: CGFloat = 30
    /// Chat and history header bar.
    static let headerHeight: CGFloat = 44

    /// The user's turn: the Models brand wash under label-coloured text, so it reads in both appearances.
    static let userBubble = WorkspaceStyle.models.soft
}

/// Library columns, defined once so the heading and every row share the same edges.
enum ModelLibraryColumns {
    static let spacing = Space.m
    static let size: CGFloat = 88
    static func status(compact: Bool) -> CGFloat { compact ? 84 : 106 }
}

/// Small status light. Pulses while something is in flight; Reduce Motion keeps it still.
struct ModelStatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .onAppear { animate(pulsing) }
            .onChange(of: pulsing) { _, now in animate(now) }
            .accessibilityHidden(true)
    }

    private func animate(_ on: Bool) {
        guard on, !reduceMotion else { dim = false; return }
        Motion.animate(Motion.heavy.repeatForever(autoreverses: true)) { dim = true }
    }
}
