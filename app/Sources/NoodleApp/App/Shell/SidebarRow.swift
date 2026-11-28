import SwiftUI

struct SidebarRow: View {
    let title: String
    let symbol: String
    let tone: WorkspaceStyle.Tone
    let selected: Bool
    var nested = false
    var badge: String?
    var detail: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: nested ? 12 : 14, weight: .medium))
                    // Neutral until selected; only the selected row carries its product colour.
                    .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.secondary))
                    .symbolVariant(selected ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, Space.xs).padding(.vertical, 1)
                        .background(selected ? AnyShapeStyle(tone.soft) : AnyShapeStyle(.quaternary), in: Capsule())
                        .fixedSize()
                        .contentTransition(.numericText())
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(tone.ink) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: nested ? 26 : 30, alignment: .leading)
            .padding(.leading, nested ? 18 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(selected ? tone.soft : .clear).padding(.horizontal, Space.s))
        .motion(Motion.snappy, value: selected)
        .motion(Motion.snappy, value: badge)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
