import SwiftUI

struct ImagesPage: View {
    /// Both fit beside the widest sidebar at the minimum window (MinimumWindowLayoutTests).
    static let listMinWidth: CGFloat = 180
    static let panelMinWidth: CGFloat = 250
    let env: AppEnvironment
    @State private var selection: Set<String> = []
    @State private var showPull = false
    @State private var narrow = false

    var body: some View {
        @Bindable var model = env.images
        let q = env.nav.search.trimmingCharacters(in: .whitespaces)
        let rows = visibleRows
        let selectedImage = selection.count == 1 ? model.items.first { selection.contains($0.id) } : nil
        HStack(spacing: 0) {
            ResourceShell(env: env, loaded: model.loaded, isEmpty: model.items.isEmpty, search: q, noMatches: rows.isEmpty,
                          empty: ResourceEmpty(symbol: "square.3.layers.3d", title: "No images",
                                               message: "Pull one from Docker Hub or any registry. Images you build or pull from the terminal show up here too.",
                                               action: showPull ? nil : ("Pull Image", env.demo, { showPull = true })),
                          summary: Fmt.count(model.items.count, "image"), error: $model.actionError) {
                table(rows, compact: narrow || showPull || selectedImage != nil)
            }
            .frame(minWidth: Self.listMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            if showPull || selectedImage != nil {
                Divider()
                Group {
                    if showPull {
                        ImagePullPanel(env: env) { showPull = false }
                    } else if let image = selectedImage {
                        ImageInspector(env: env, image: image) { selection.removeAll() }
                            .id(image.id)
                    }
                }
                .frame(minWidth: Self.panelMinWidth, idealWidth: 340, maxWidth: 380, maxHeight: .infinity)
            }
        }
        .onChange(of: selection) { _, selection in if !selection.isEmpty { showPull = false } }
        .onChange(of: q) { selection.formIntersection(visibleRows.map(\.id)) }
        .pageActions([
            PageAction(id: "pull-image", title: "Pull Image", symbol: "arrow.down.circle", disabled: env.demo || showPull) {
                selection.removeAll()
                showPull = true
            },
            PageAction(id: "delete", title: "Delete", symbol: "trash", disabled: selection.isEmpty) { confirm(Array(selection)) },
        ])
    }

    private var visibleRows: [ImageSummary] {
        env.images.items.filter { ListFilter.matches(env.nav.search, $0.displayName, $0.shortID) }
    }

    private func table(_ rows: [ImageSummary], compact: Bool) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { image in
                HStack(spacing: 7) {
                    ImageGlyph(reference: image.displayName, size: 20)
                    Text(image.displayName).lineLimit(1).help(image.displayName)
                }
            }.width(min: 90, ideal: 230)
            TableColumn("Size") { i in Text(Fmt.bytes(i.size)).monospacedDigit() }.width(80)
            if !compact {
                TableColumn("Created") { i in Text(Fmt.ago(i.created)).foregroundStyle(.secondary) }.width(100)
                TableColumn("In use") { i in
                    if i.containers > 0 { Label("\(i.containers)", systemImage: "shippingbox").labelStyle(.titleAndIcon) }
                }.width(64)
                TableColumn("ID") { i in Text(i.shortID).font(.body.monospaced()).foregroundStyle(.secondary) }.width(110)
            }
        }
        .resourceRows(selection: $selection, narrow: $narrow, confirm: confirm) { ids in
            Button("Copy ID", systemImage: "doc.on.doc") { copyToPasteboard(ids.first ?? "") }.disabled(ids.count != 1)
            Divider()
        }
    }

    private func confirm(_ all: [String]) {
        env.confirmDelete(all, visible: visibleRows.map(\.id), selection: $selection,
                          title: { $0.count == 1 ? String(localized: "Delete this image?") : String(localized: "Delete \($0.count) images?") },
                          message: String(localized: "Images used by a container can’t be deleted until the container is removed.")) { await env.images.remove($0) }
    }
}
