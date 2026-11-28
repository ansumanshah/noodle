import SwiftUI
import AppKit

/// A radio choice with a name and one fact. The whole row is the control.
struct SetupRadioRow: View {
    let title: String
    var detail = ""
    var code = ""
    let selected: Bool
    let choose: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .imageScale(.large).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
                    if !code.isEmpty { InlineCommand(command: code) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.panel).padding(.vertical, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hover ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .motion(Motion.snappy, value: hover)
        .accessibilityLabel(title).accessibilityHint(detail + code)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
