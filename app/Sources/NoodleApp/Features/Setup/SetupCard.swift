import SwiftUI
import AppKit

/// Native-looking grouped list: one rounded surface, hairline separators, no shadow.
struct SetupList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .box(padding: 0)
    }
}

struct SetupRule: View {
    var body: some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: Control.hairline).padding(.leading, Space.panel) }
}

/// A page title, and one short line only where a decision needs it.
struct SetupPageHeader: View {
    let title: String
    var detail = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.title2.weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// Setup commands share the terminal's syntax colours. Paths use plain mono text.
struct SetupCode: View {
    let text: String
    var body: some View { InlineCommand(command: text) }
}

/// A status mark that follows the symbol table: done, warning. Gray unless it warns.
struct SetupStatusMark: View {
    enum Kind { case done, warning }
    let kind: Kind
    var body: some View {
        Image(systemName: kind == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .imageScale(.large).symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind == .done ? Color.secondary : Status.warning)
            .contentTransition(.symbolEffect(.replace))
            .motion(Motion.snappy, value: kind)
            .accessibilityLabel(kind == .done ? "Done" : "Needs attention")
    }
}
