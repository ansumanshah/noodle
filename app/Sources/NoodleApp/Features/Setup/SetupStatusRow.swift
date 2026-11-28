import SwiftUI
import AppKit

/// A row of the first-container list: a name plus one fact, and where it stands.
struct SetupStatusRow: View {
    let row: SetupProgressRow
    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.title).font(.headline)
                Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if case .active(let fraction?) = row.state { ProgressView(value: fraction).progressViewStyle(.linear).frame(maxWidth: 240) }
            }
            Spacer(minLength: 8)
            switch row.state {
            case .waiting: Text("Waiting").font(.callout).foregroundStyle(.secondary)
            case .active: ProgressView().controlSize(.small)
            case .done: SetupStatusMark(kind: .done)
            case .failed: SetupStatusMark(kind: .warning)
            }
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, minHeight: SetupSheetContent.barHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
