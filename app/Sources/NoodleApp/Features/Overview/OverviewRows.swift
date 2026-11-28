import SwiftUI
import AppKit

/// Rows with a hairline between each pair.
struct OverviewRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { OverviewDivider() }
                // Reduce Motion keeps the fade and drops the scale.
                row(item).transition(reduceMotion ? .opacity : .row)
            }
        }
    }
}
