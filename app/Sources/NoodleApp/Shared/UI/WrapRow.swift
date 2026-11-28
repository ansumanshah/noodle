import SwiftUI

/// Lays subviews out left to right at their ideal size and starts a new line when the next one would not fit.
struct WrapRow: Layout {
    var spacing: CGFloat = Space.xs
    var lineSpacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = Self.frames(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? .infinity,
                                 spacing: spacing, lineSpacing: lineSpacing)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        for (subview, frame) in zip(subviews, Self.frames(sizes, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY), anchor: .leading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each item's frame; items on one line share the line's height and are centred in it.
    static func frames(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            if !lines[lines.count - 1].isEmpty, x + spacing + size.width > width { lines.append([]); x = 0 }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append(i)
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for i in line {
                frames[i] = CGRect(x: x, y: y + (height - sizes[i].height) / 2, width: sizes[i].width, height: sizes[i].height)
                x += sizes[i].width + spacing
            }
            y += height + lineSpacing
        }
        return frames
    }
}
