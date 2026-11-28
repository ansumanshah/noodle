// Portions Copyright (c) 2026 David Dalcu. MIT License; see NOTICE.
import Foundation

/// Sample before an append: existing viewport geometry belongs to the reader.
/// Never animate token appends, including when Reduce Motion is disabled.
enum ModelResponseScrollPolicy {
    static func followsAppend(distanceFromBottom: CGFloat, hasSelection: Bool) -> Bool {
        !hasSelection && distanceFromBottom <= 32
    }

    static func distanceFromBottom(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        contentHeight - (offsetY + viewportHeight)
    }
}
