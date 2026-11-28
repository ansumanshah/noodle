import SwiftUI

extension View {
    /// Sets `value` back to `rest` after `delay`. Setting it again restarts the wait, and leaving the view cancels it.
    /// Drives the "Copied" confirmation: `.autoReset($copied, to: false)` or `.autoReset($copiedApp, to: nil)`.
    func autoReset<T: Equatable>(_ value: Binding<T>, to rest: T, after delay: Duration = .seconds(1.5)) -> some View {
        task(id: value.wrappedValue) {
            guard value.wrappedValue != rest else { return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { value.wrappedValue = rest }
        }
    }
}
