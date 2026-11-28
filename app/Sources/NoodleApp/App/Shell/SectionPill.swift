import SwiftUI

/// Every sidebar row of the current mode in the same track as ModeSwitcher. The selected page shows its full name on a raised
/// segment that springs between pages; the rest are icon-only squares.
struct SectionPill: View {
    let env: AppEnvironment
    /// Narrowest header: the selected page drops its name too.
    var iconsOnly = false
    @Namespace private var selection
    private let side = Control.height - 2 * Space.xxs

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(env.nav.mode.routes) { route in segment(route) }
        }
        .padding(Space.xxs)
        .controlSurface()
        .motion(Motion.snappy, value: env.nav.route)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func segment(_ route: Route) -> some View {
        let selected = env.nav.route == route
        return Button {
            env.nav.search = ""
            env.nav.go(.route(route))
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: route.symbol).symbolVariant(selected ? .fill : .none)
                if selected, !iconsOnly { Text(route.title).fontWeight(.semibold).fixedSize() }
            }
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(selected ? AnyShapeStyle(route.tone.ink) : AnyShapeStyle(.secondary))
            .padding(.horizontal, selected && !iconsOnly ? Space.m : 0)
            .frame(minWidth: side, minHeight: side)
            .frame(height: side)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Control.radius, style: .continuous)
                        .fill(route.tone.soft)
                        .matchedGeometryEffect(id: "selected", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(route.title)
        .accessibilityLabel(route.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("toolbar-section-\(route.rawValue)")
    }
}
