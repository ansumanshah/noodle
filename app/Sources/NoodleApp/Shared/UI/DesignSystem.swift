import SwiftUI

// One design system for every product. Geometry here never varies by product; colour comes only from the route's
// `productTone` (see `WorkspaceStyle.Tone`).
/// Spacing tokens. Pages use `page` for outer margins, panels `panel` inside, rows `row` between items.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let panel: CGFloat = 16
    static let l: CGFloat = 18
    static let page: CGFloat = 22
    static let xl: CGFloat = 24
    /// Window toolbar outer inset, left and right: the page margin, so header controls line up with the content below.
    static let toolbarInset = page
}

/// Corner radii, smallest to largest: fields and code, controls and grouped panels, cards and window-level surfaces.
enum Radius {
    static let control: CGFloat = 8
    static let panel: CGFloat = 10
    static let card: CGFloat = 12
}

/// One row height for every list and table, so pages line up when you switch between them.
enum RowSize {
    static let height: CGFloat = 28
}

/// One size, shape and gap for every in-page control (fields, buttons, pickers, menus); chips are a step shorter.
enum Control {
    static let height: CGFloat = 32
    static let chipHeight: CGFloat = 28
    /// Items inside the window toolbar (host chip, section pill), which the system keeps shorter than page controls.
    static let barHeight: CGFloat = 24
    static let radius = Radius.panel
    static let gap = Space.s
    static let hairline: CGFloat = 0.5
    /// A selection or focus ring.
    static let ring: CGFloat = 1.5
    /// The on/off switch, the size of a regular macOS switch.
    static let switchSize = CGSize(width: 38, height: 22)
}

/// Icon tiles and status dots, so the same glyph is the same size on every page.
enum Tile {
    static let size: CGFloat = 40
    static let hero: CGFloat = 48
    /// The app icon heading an onboarding page.
    static let appIcon: CGFloat = 64
    static let dot: CGFloat = 8
}

/// Start and Stop colours. Everything else neutral; orange only for semantic warnings, red for Stop and errors.
enum Status {
    static let running = Color(nsColor: .systemGreen)
    static let stopped = Color(nsColor: .systemRed)
    static let error = stopped
    static let warning = Color(nsColor: .systemOrange)
}

extension View {
    /// Rows at the shared height. Lists and tables only grow past it when a row needs two lines.
    func standardRows() -> some View { environment(\.defaultMinListRowHeight, RowSize.height) }

    /// A grouped surface on the content layer: neutral fill, no border, optional wash of the page's product colour.
    func cardSurface(padding: CGFloat = Space.panel, tinted: Bool = true) -> some View { modifier(CardSurface(padding: padding, tinted: tinted)) }

    /// The one control surface: `Control.height`, `Control.radius`, neutral fill, no border. Tinted controls (Start, Stop) keep their hue.
    func controlSurface(tint: Color = .primary, pressed: Bool = false, hovered: Bool = false, radius: CGFloat = Control.radius) -> some View {
        modifier(ControlSurface(tint: tint, pressed: pressed, hovered: hovered, radius: radius))
    }

    /// The one error or warning surface: a faint fill of `tint` (`Status.error` or `Status.warning`).
    func errorSurface(_ tint: Color = Status.error, radius: CGFloat = Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(tint.opacity(0.1)))
    }

    /// Hover feedback for a borderless or plain button: a soft fill behind the label while the pointer is over it.
    /// `active` false turns it off, for the selected segment of a switcher.
    func hoverFill(radius: CGFloat = Radius.control, active: Bool = true, outset: CGFloat = 4) -> some View {
        modifier(HoverFill(radius: radius, active: active, outset: outset))
    }

    /// Hover and selection feedback for list rows; snappy spring, Reduce Motion aware.
    func rowHover(_ hovering: Bool, selected: Bool) -> some View { modifier(RowHover(hovering: hovering, selected: selected)) }
}

/// Line and fill strength per appearance: white content needs firmer values than dark content to show at all.
extension ColorScheme {
    var controlLine: Double { self == .dark ? 0.1 : 0.2 }
    var cardFill: Double { self == .dark ? 0.07 : 0.045 }
}

private struct HoverFill: ViewModifier {
    let radius: CGFloat
    let active: Bool
    let outset: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        // The fill reaches `outset` past a bare icon so it reads as a target, without changing the layout.
        content
            .background(Color.secondary.opacity(hovered && active && isEnabled ? 0.14 : 0),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: -outset))
            .onHover { hovered = $0 }
            .motion(Motion.snappy, value: hovered)
    }
}

private struct ControlSurface: ViewModifier {
    let tint: Color
    let pressed: Bool
    var hovered = false
    var radius = Control.radius

    func body(content: Content) -> some View {
        let neutral = tint == .primary
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Three steps of one fill: rest, hover, pressed.
        let fill = pressed ? (neutral ? 0.16 : 0.26) : hovered ? (neutral ? 0.12 : 0.21) : (neutral ? 0.07 : 0.15)
        content.frame(height: Control.height)
            .glassSurface(radius: radius, tint: tint)
            .background(tint.opacity(fill), in: shape)
    }
}

extension View {
    /// Keeps `narrow` true while this view is under `below` points wide, so a table can drop its secondary columns.
    func trackNarrow(_ narrow: Binding<Bool>, below: CGFloat = 640) -> some View {
        onGeometryChange(for: Bool.self) { $0.size.width < below } action: { narrow.wrappedValue = $0 }
    }
}

private struct CardSurface: ViewModifier {
    let padding: CGFloat
    let tinted: Bool
    @Environment(\.productTone) private var tone
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content.padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassSurface(radius: Radius.card)
            .background(tinted ? Color.secondary.opacity(scheme.cardFill) : Color.clear, in: shape)
            .background { if tinted { Color.clear.toneWash(tone) } }
    }
}

private struct RowHover: ViewModifier {
    let hovering: Bool
    let selected: Bool
    @Environment(\.productTone) private var tone
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let selectedFill = tone.soft
        return content
            .background(Rectangle().fill(selected ? selectedFill : Color.secondary.opacity(hovering ? (scheme == .light ? 0.12 : 0.08) : 0)))
            .motion(Motion.snappy, value: hovering)
            .motion(Motion.snappy, value: selected)
    }
}

/// The app's one button, text or `square` icon, always `Control.height` tall. `tint` nil is the page's primary action
/// in its product colour; neutral actions pass `.primary`; Start and Stop pass `Status`. Keeps its tint in every window
/// state (a prominent bordered button greys out when the window is not key, which would break Start-is-green).
struct ControlButtonStyle: ButtonStyle {
    var tint: Color?
    var square = false
    /// Stretch to the container's width instead of hugging the label.
    var fill = false
    /// Fully rounded: a capsule, or a circle when `square`. For onboarding pages, whose buttons sit alone and centred.
    var round = false
    func makeBody(configuration: Configuration) -> some View { Hoverable(style: self, configuration: configuration) }

    /// A view, so the button can hold its hover state.
    private struct Hoverable: View {
        let style: ControlButtonStyle
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.productTone) private var tone
        @State private var hovered = false

        var body: some View { style.label(configuration, tone: tone, isEnabled: isEnabled, hovered: hovered).onHover { hovered = $0 } }
    }

    private func label(_ configuration: Configuration, tone: WorkspaceStyle.Tone, isEnabled: Bool, hovered: Bool) -> some View {
        let color = tint ?? tone.ink
        let radius = round ? Control.height / 2 : Control.radius
        return configuration.label
            .font(.callout.weight(.semibold))
            .labelStyle(SquareAwareLabelStyle(iconOnly: square))
            .lineLimit(1).fixedSize(horizontal: !fill, vertical: true)
            .foregroundStyle(color)
            .padding(.horizontal, square ? 0 : Space.m)
            .frame(width: square ? Control.height : nil)
            .frame(maxWidth: fill ? .infinity : nil)
            .controlSurface(tint: tint == nil ? tone.base : color, pressed: configuration.isPressed, hovered: hovered && isEnabled, radius: radius)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect(cornerRadius: radius, style: .continuous))
            .motion(Motion.snappy, value: configuration.isPressed)
            .motion(Motion.snappy, value: hovered)
    }
}

extension ButtonStyle where Self == ControlButtonStyle {
    /// The page's primary action, in its product colour.
    static var primaryAction: ControlButtonStyle { ControlButtonStyle() }
    /// A neutral action.
    static var neutralAction: ControlButtonStyle { ControlButtonStyle(tint: .primary) }
    /// A neutral icon-only action, `Control.height` square.
    static var iconAction: ControlButtonStyle { ControlButtonStyle(tint: .primary, square: true) }
    /// The primary action as a capsule, and a neutral round icon button beside it.
    static var capsuleAction: ControlButtonStyle { ControlButtonStyle(round: true) }
    static var roundIconAction: ControlButtonStyle { ControlButtonStyle(tint: .primary, square: true, round: true) }
}

private struct SquareAwareLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}

/// The one search field: magnifier, plain text field, clear button, on the control surface.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?
    @FocusState private var inner: Bool
    @Environment(\.productTone) private var tone

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(.secondary))
                .textFieldStyle(.plain).labelsHidden().accessibilityLabel(prompt).focused($inner)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.m).controlSurface()
        .overlay {
            if inner {
                RoundedRectangle(cornerRadius: Control.radius, style: .continuous).strokeBorder(tone.base.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle()).onTapGesture { inner = true }
        .onChange(of: inner) { _, now in focus?.wrappedValue = now }
        .onChange(of: focus?.wrappedValue) { _, now in if let now { inner = now } }
        // A field that appears already asked for focus (the toolbar search unfolding) takes it.
        .onAppear { if focus?.wrappedValue == true { inner = true } }
    }
}

/// The one menu picker: current value and an up/down chevron on the control surface, so it reads as clickable.
struct MenuPicker<Value: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: Space.xs) {
                Text(value).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, Space.m).controlSurface()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(title).accessibilityValue(value)
    }
}

/// The one filter chip: title and count, `Control.chipHeight` tall, the selected one on a product-tinted fill that
/// slides between chips. Pass the same `Namespace` to every chip in a row.
struct FilterChip: View {
    let title: String
    var count: Int?
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.productTone) private var tone

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.callout.weight(selected ? .semibold : .medium)).lineLimit(1).fixedSize()
                if let count {
                    Text("\(count)").font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .foregroundStyle(selected ? tone.ink : Color.secondary)
            .padding(.horizontal, Space.m).frame(height: Control.chipHeight)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Control.radius, style: .continuous)
                        .fill(tone.soft)
                        .matchedGeometryEffect(id: "chip", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of `FilterChip`s over one selection, the replacement for a segmented picker.
struct FilterChips<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Namespace private var space

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(items, id: \.self) { item in
                FilterChip(title: title(item), selected: selection == item, namespace: space) { selection = item }
            }
        }
        .motion(Motion.snappy, value: selection)
    }
}
