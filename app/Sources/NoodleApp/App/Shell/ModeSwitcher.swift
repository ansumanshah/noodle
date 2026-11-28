import SwiftUI

/// The three modes (Models, Containers, Runners) as one segmented control in the window toolbar. The selected
/// segment carries the mode's tone and slides between modes; Command-1 to Command-3 live in the View menu.
struct ModeSwitcher: View {
    let nav: NavigationModel
    /// Narrow window: only the selected mode keeps its name.
    var compact = false
    /// Narrowest header: no mode keeps its name; the tone still marks the selected one.
    var iconsOnly = false
    @Namespace private var space

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(Route.Mode.allCases) { segment($0) }
        }
        .padding(Space.xxs)
        .controlSurface()
        .motion(Motion.snappy, value: nav.mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
        .accessibilityIdentifier("mode-switcher")
    }

    private func segment(_ mode: Route.Mode) -> some View {
        let selected = nav.mode == mode
        return Button { Motion.animate(Motion.standard) { nav.switchMode(mode) } } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: mode.symbol).symbolVariant(selected ? .fill : .none)
                if !iconsOnly, !compact || selected { Text(mode.title).fontWeight(selected ? .semibold : .medium) }
            }
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(selected ? AnyShapeStyle(mode.tone.ink) : AnyShapeStyle(.secondary))
            .padding(.horizontal, iconsOnly || (compact && !selected) ? Space.s : Space.m)
            .frame(height: Control.height - 2 * Space.xxs)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Control.radius, style: .continuous)
                        .fill(mode.tone.soft)
                        .matchedGeometryEffect(id: "mode", in: space)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(radius: Control.radius, active: !selected, outset: 0)
        .help("\(mode.title) (⌘\(String(mode.shortcutKey.character)))")
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("mode-\(mode.rawValue)")
    }
}
