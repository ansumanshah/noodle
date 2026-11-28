import SwiftUI

struct RuntimeCard<Rows: View, Footer: View>: View {
    let title: String
    let status: String
    /// Drives the green state; `status` is display text and is never compared.
    let running: Bool
    @ViewBuilder var rows: Rows
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 5) {
                HStack(alignment: .center, spacing: 5) {
                    Text(title).fontWeight(.semibold).lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        StateDot(state: running ? "running" : "exited", size: 6)
                        Text(status).fontWeight(.medium)
                            .foregroundStyle(running ? AnyShapeStyle(Status.running) : AnyShapeStyle(.secondary))
                            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Space.xs).padding(.vertical, 2)
                    .background((running ? Status.running : Color.secondary).opacity(0.12), in: .capsule)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(status)
            }
            rows
            footer
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The card's last line: Refresh and Settings, which used to live in the window footer.
struct RuntimeCardFooter: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The card's status pill already says what runs, so the footer holds only its two controls.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await env.sync.refreshWorkspace()
                        if env.nav.route.isModels { await env.modelsStore.refresh() }
                    }
                }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().foregroundStyle(.secondary)
                    .help("Refresh (⌘R)")
                Button("Settings", systemImage: "gearshape") { openSettings() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
            }
            // A bar the height of a control, like the page footers, so both bottom lines share one baseline.
            .frame(height: Control.height)
        }
    }
}

struct RuntimeCardRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 2)
            Text(verbatim: value).monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}

/// The footer's status: a dot (a spinner while busy) and the product-named state, the same for every mode.
