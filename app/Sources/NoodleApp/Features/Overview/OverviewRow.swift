import SwiftUI
import AppKit

/// A full-width row: gray hover, no disclosure arrow, selecting it opens the thing. Optional trailing
/// actions appear on hover or keyboard focus of the row or of any action in it; a right-click menu carries
/// the same actions. The actions stay in the view tree (clear when idle), so Tab can reach them.
struct OverviewRow<Label: View, Trailing: View, Menu: View>: View {
    let accessibilityLabel: String
    var value = ""
    let action: () -> Void
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var menu: Menu
    @State private var hovering = false
    @FocusState private var focused: Bool

    /// The trailing actions' width, so the label can fade out under them instead of showing through.
    @State private var trailingWidth: CGFloat = 0

    private var revealed: Bool { hovering || focused || DemoFlags.revealRow == accessibilityLabel }
    private var hasTrailing: Bool { Trailing.self != EmptyView.self }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                label.environment(\.overviewRowRevealed, revealed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Values under the revealed actions fade out; an opaque patch over them showed clipped letters.
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            if revealed, hasTrailing {
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Space.panel)
                                Color.clear.frame(width: trailingWidth)
                            }
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel).accessibilityValue(value)
        }
        // Over the row, not beside it, so hidden actions never push values away from the edge.
        .overlay(alignment: .trailing) {
            if hasTrailing {
                trailing
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
            }
        }
        // A Boolean focus binding includes descendants, including each trailing action.
        .focused($focused)
        .frame(minHeight: 28)
        .padding(.horizontal, Space.panel).padding(.vertical, Space.xs)
        // A soft rounded fill inside the card, not an opaque band across it.
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.primary.opacity(revealed ? 0.07 : 0))
                // The gap keeps the fills of two neighbouring rows from touching while one fades out and the next fades in.
                .padding(.horizontal, Space.s).padding(.vertical, 1)
        }
        .padding(.horizontal, -16)
        .onHover { hovering = $0 }
        .motion(Motion.snappy, value: revealed)
        .contextMenu { menu }
    }
}

/// A row value that steps aside while the row's actions show in its place.
struct HiddenWhileRevealed<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.overviewRowRevealed) private var revealed
    var body: some View { content.opacity(revealed ? 0 : 1) }
}

extension OverviewRow where Trailing == EmptyView, Menu == EmptyView {
    init(accessibilityLabel: String, value: String = "", action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(accessibilityLabel: accessibilityLabel, value: value, action: action, label: label,
                  trailing: { EmptyView() }, menu: { EmptyView() })
    }
}
