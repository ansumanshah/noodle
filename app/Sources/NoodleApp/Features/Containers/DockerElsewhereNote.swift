import NoodleCore
import SwiftUI

/// Shown on Containers while plain `docker` goes to another engine, because that is where the gap is visible.
struct DockerElsewhereNote: View {
    let target: String
    let choose: () -> Void
    let dismiss: () -> Void

    /// "Docker Desktop" for its context name, else the name as Docker shows it.
    private var name: String { SetupEngine(name: target, socket: "", reachable: false, inUse: true).displayName }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("docker in your terminal goes to \(name), so containers you start there appear in \(name), not here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Use Noodle for docker…", action: choose).buttonStyle(.neutralAction)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
        }
        .padding(.horizontal, Space.page).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.035))
    }
}
