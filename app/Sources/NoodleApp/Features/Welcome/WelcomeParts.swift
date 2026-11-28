import SwiftUI

/// The product's icon on a tint of its own colour, the same tile the Models download card uses.
struct WelcomeProductIcon: View {
    let product: WelcomeProduct

    var body: some View {
        let tone = product.mode.tone
        Image(systemName: product.mode.symbol).font(.title3.weight(.semibold))
            .foregroundStyle(tone.ink)
            .frame(width: Tile.size, height: Tile.size)
            .background(tone.base.opacity(0.16), in: .rect(cornerRadius: Radius.panel, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One product on the first screen. Selected: a ring and a check in the product's colour.
struct WelcomeTile: View {
    let product: WelcomeProduct
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let tone = product.mode.tone
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        Button(action: action) {
            VStack(spacing: Space.s) {
                WelcomeProductIcon(product: product)
                Text(product.mode.title).font(.headline)
                Text(product.line).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.panel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(selected ? tone.soft : Color.secondary.opacity(hovered ? 0.1 : 0), in: shape)
            .overlay(shape.strokeBorder(selected ? tone.base : Color.primary.opacity(0.1), lineWidth: selected ? Control.ring : Control.hairline))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.base)
                    .padding(Space.s).opacity(selected ? 1 : 0).scaleEffect(selected ? 1 : 0.6)
                    .accessibilityHidden(true)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .motion(Motion.snappy, value: selected)
        .motion(Motion.snappy, value: hovered)
        .accessibilityLabel("\(product.mode.title). \(product.line)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("welcome-tile-\(product.rawValue)")
    }
}

/// The small neutral word under a column's name: what is true right now.
struct WelcomeStatusCapsule: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, Space.s).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .contentTransition(.opacity)
    }
}

/// What a column's button turns into once its step is finished.
struct WelcomeDoneCapsule: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark").font(.callout.weight(.semibold))
            .foregroundStyle(Status.running)
            .padding(.horizontal, Space.m).frame(height: Control.height)
            .background(Status.running.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "\(text), done"))
    }
}

/// One card holding a column per product, split by hairlines. Every column gets the tallest column's height.
struct WelcomeColumns<Column: View>: View {
    let products: [WelcomeProduct]
    @ViewBuilder let column: (WelcomeProduct) -> Column

    var body: some View {
        HStack(spacing: 0) {
            ForEach(products) { product in
                if product != products.first {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: Control.hairline)
                }
                column(product).padding(.horizontal, Space.m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .cardSurface(tinted: false)
    }
}

/// Icon, name, an optional status, one line, and the slot for the action, top to bottom.
struct WelcomeColumn<Detail: View, Action: View>: View {
    let product: WelcomeProduct
    let title: String
    var status: String?
    @ViewBuilder let detail: Detail
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: Space.s) {
            WelcomeProductIcon(product: product)
            VStack(spacing: Space.xxs) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let status { WelcomeStatusCapsule(text: status) }
            }
            detail.font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action.frame(height: Control.height)
        }
        .environment(\.productTone, product.mode.tone)
        .accessibilityElement(children: .contain)
    }
}
