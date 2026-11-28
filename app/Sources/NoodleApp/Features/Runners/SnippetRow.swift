import SwiftUI

/// A line to paste into a workflow, with a copy button.
struct SnippetRow: View {
    let label: String
    let text: String
    @State private var copied = false
    var body: some View {
        HStack(spacing: Space.s) {
            Text(label)
            Spacer()
            HStack(spacing: Space.s) {
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyToPasteboard(text)
                    copied = true
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                .contentTransition(.symbolEffect(.replace))
            }
        }
        .autoReset($copied, to: false)
    }
}
