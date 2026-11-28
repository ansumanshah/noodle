import SwiftUI
import AppKit

/// Everything this Mac already has, in one line, with the one fact that matters: where docker is.
struct SetupFoundRow: View {
    let summary: String
    let fact: String?
    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(summary).font(.headline)
                if let fact { Text(fact).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            SetupStatusMark(kind: .done)
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, minHeight: SetupSheetContent.barHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
