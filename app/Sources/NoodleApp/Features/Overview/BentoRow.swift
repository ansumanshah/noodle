import SwiftUI
import AppKit

/// Tiles in one row, widths by weight, all as tall as the tallest. Missing tiles let the rest fill the row.
struct BentoRow: Layout {
    var weights: [CGFloat]
    /// The spec's 20 pt between groups.
    var spacing: CGFloat = 20

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let w = weights.count == count ? weights : Array(repeating: 1, count: count)
        let free = total - spacing * CGFloat(count - 1)
        return w.map { free * $0 / w.reduce(0, +) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let cols = widths(total, count: subviews.count)
        let height = zip(subviews, cols).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
