// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
import SwiftUI

/// View switcher used across the app: icon and title chips, the selected one on a brand-tinted fill that
/// slides between chips (matched geometry, snappy spring, Reduce Motion aware).
struct ChipTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var symbol: (Tab) -> String? = { _ in nil }
    var badge: (Tab) -> String? = { _ in nil }
    var identifier: (Tab) -> String? = { _ in nil }
    var compact = false
    @Namespace private var chip
    @Environment(\.productTone) private var tone

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(tabs) { tab in
                let id = identifier(tab)
                Button { selection = tab } label: { label(tab) }
                    .buttonStyle(.plain)
                    .hoverFill(radius: Control.radius, active: selection != tab, outset: 0)
                    .accessibilityLabel(title(tab))
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .modifier(OptionalIdentifier(id: id))
            }
        }
        .motion(Motion.snappy, value: selection)
    }

    private func label(_ tab: Tab) -> some View {
        let selected = selection == tab
        return HStack(spacing: 6) {
            if let symbol = symbol(tab) {
                Image(systemName: symbol).font(.subheadline.weight(.medium))
                    .symbolVariant(selected ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(title(tab)).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
            if let badge = badge(tab) {
                Text(badge).font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, Space.xs).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.secondary))
        .padding(.horizontal, compact ? Space.s : Space.m).frame(height: Control.chipHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Control.radius, style: .continuous)
                    .fill(tone.soft)
                    .matchedGeometryEffect(id: "selected", in: chip)
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
    }
}

private struct OptionalIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}
