import SwiftUI

/// Failure card: the app's own voice, what happened,
/// the one action that helps, and Dismiss.
struct ErrorCard: View {
    let title: String
    let detail: String
    var action: (title: String, disabled: Bool, run: () -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.title3.weight(.medium)).foregroundStyle(Status.error)
                .padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Status.error)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    if let action {
                        Button(action: action.run) {
                            Label(action.title, systemImage: "arrow.clockwise")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(action.disabled)
                    }
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                        .help("Dismiss error")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.panel)
        .errorSurface(radius: ModelsChrome.bubbleRadius)
        .transition(.slide(from: .top))
    }
}
