import SwiftUI

/// Screen 3: one place to start per chosen product.
struct WelcomeDoneCard: View {
    let flow: WelcomeFlow
    let open: (Route) -> Void
    static let command = "docker run --rm alpine echo hello"
    @State private var copied = false

    var body: some View {
        WelcomeColumns(products: flow.products) { product in
            switch product {
            case .models:
                WelcomeColumn(product: product, title: String(localized: "Start a chat")) {
                    Text("Ask anything. It stays on this Mac.")
                } action: {
                    Button("Open Chat") { open(.chat) }.buttonStyle(.neutralAction)
                }
            case .containers:
                WelcomeColumn(product: product, title: String(localized: "Run a container")) {
                    InlineCommand(command: Self.command, wraps: true)
                } action: {
                    Button { copyToPasteboard(Self.command); copied = true } label: {
                        Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.neutralAction)
                    .motion(Motion.snappy, value: copied)
                }
            case .runners:
                WelcomeColumn(product: product, title: String(localized: "Add a repo")) {
                    Text("Pick a repo and its jobs run here.")
                } action: {
                    Button("Open Runners") { open(.runners) }.buttonStyle(.neutralAction)
                }
            }
        }
    }
}
