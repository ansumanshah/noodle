import SwiftUI

/// What a resource page shows when it has no rows.
struct ResourceEmpty {
    let symbol: String
    let title: String
    let message: String
    var command: String?
    var action: (title: String, disabled: Bool, run: () -> Void)?
}

struct ResourceShell<Content: View>: View {
    let env: AppEnvironment
    let loaded: Bool
    let isEmpty: Bool
    let search: String
    let noMatches: Bool
    let empty: ResourceEmpty
    var summary = ""
    let error: Binding<String?>
    @ViewBuilder var content: Content

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if case .down(let m) = env.connection.phase, !loaded { DaemonDownView(env: env, message: m).transition(.opacity) }
                else if !loaded { LoadingState(label: String(localized: "Loading…")).transition(.opacity) }
                else if isEmpty {
                    EmptyState(symbol: empty.symbol, title: empty.title, message: empty.message, command: empty.command, action: empty.action)
                        .transition(.opacity)
                }
                else if noMatches { EmptyState.search(search).transition(.opacity) }
                else { content.transition(.opacity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { if let e = error.wrappedValue { ErrorBanner(message: e) { error.wrappedValue = nil } } }
        }
        .pageSummary(loaded && !isEmpty ? summary : nil)
        .motion(Motion.standard, value: loaded)
        .motion(Motion.standard, value: isEmpty)
    }
}
