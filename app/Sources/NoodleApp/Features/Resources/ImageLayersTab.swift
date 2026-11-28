import SwiftUI

/// One build step of an image, base first. Docker's history supplies the steps and Noodle's catalog the stored layers.
struct ImageLayerRow: Identifiable, Equatable {
    let id: Int
    let instruction: String
    let size: Int
    /// Set when the step wrote a layer. Steps such as ENV and CMD write none.
    let digest: String?
    let created: Int?

    /// Docker history lists the newest step first. Pair its filesystem steps with the base-first catalog.
    /// A repeated instruction on a metadata-only step cannot take a layer's digest.
    static func merge(history: [ImageHistory], catalog: [CatalogImageLayer]?) -> [ImageLayerRow] {
        let layers = catalog ?? []
        let steps = history.reversed()
        if !layers.isEmpty, steps.filter({ $0.size > 0 }).map(\.createdBy) != layers.map(\.instruction) {
            return layers.enumerated().map { index, layer in
                ImageLayerRow(id: index + 1, instruction: layer.instruction, size: layer.size, digest: layer.digest, created: nil)
            }
        }
        var stored = layers.makeIterator()
        return steps.enumerated().map { index, step in
            let layer = step.size > 0 ? stored.next() : nil
            return ImageLayerRow(id: index + 1, instruction: step.createdBy, size: layer?.size ?? step.size,
                                 digest: layer?.digest, created: step.created)
        }
    }

    /// The Dockerfile line, without the shell wrapper older builders record.
    var command: String {
        var text = instruction.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/bin/sh -c #(nop)") { return String(text.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
        if text.hasPrefix("/bin/sh -c ") { text = "RUN " + text.dropFirst(11) }
        return text.isEmpty ? "Image layer" : text
    }
}

struct ImageLayersTab: View {
    let rows: [ImageLayerRow]
    let loading: Bool
    let failure: String?

    var body: some View {
        if loading {
            ProgressView("Loading layers…").padding(Space.panel)
        } else if rows.isEmpty {
            Text(failure ?? "No layer history is recorded for this image.").foregroundStyle(.secondary).padding(Space.panel)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let stored = rows.filter { $0.digest != nil }.count
                    Text(stored > 0 ? "\(rows.count) steps, \(stored) stored layers. Base first."
                                    : "\(rows.count) steps. Base first.")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, Space.panel).padding(.vertical, Space.s)
                    ForEach(rows) { row in
                        Divider()
                        LayerRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct LayerRowView: View {
    let row: ImageLayerRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(row.id)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.command).font(.callout.monospaced()).lineLimit(4).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(row.size > 0 || row.digest != nil ? Fmt.bytes(row.size) : "No files").monospacedDigit()
                    if let created = row.created, created > 0 { Text(Fmt.ago(created)) }
                }.font(.caption).foregroundStyle(.secondary)
                if let digest = row.digest {
                    Text(digest).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(digest)
                }
            }
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
