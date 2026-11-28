import SwiftUI

/// A calm note under the failed message: the Mac is short on memory right now, so trying again is reasonable.
struct ModelMemoryNote: View {
    let busy: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "memorychip").foregroundStyle(Status.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelMemoryRefusal.title).font(.callout.weight(.medium))
                Text(ModelMemoryRefusal.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Button("Try Again", action: retry).disabled(busy)
            Button("Dismiss", action: dismiss).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .errorSurface(Status.warning)
        .padding(.horizontal, Space.page)
        .accessibilityElement(children: .contain)
    }
}
