import Foundation
import NoodleCore
import SwiftUI

struct ModelLibraryView: View {
    let store: ModelsPageStore
    let importModel: () -> Void
    let removeModel: (LocalModel) -> Void
    let selectModel: (LocalModel) -> Void
    @State private var query = ""
    @State private var filter: ModelLibraryFilter
    @State private var kind: ModelKindFilter?
    @State private var selectedID: String?

    init(store: ModelsPageStore, initialFilter: ModelLibraryFilter = .all, importModel: @escaping () -> Void,
         removeModel: @escaping (LocalModel) -> Void, selectModel: @escaping (LocalModel) -> Void) {
        self.store = store
        self.importModel = importModel
        self.removeModel = removeModel
        self.selectModel = selectModel
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let downloading = ModelLibraryPolicy.downloadingID(store.activity)
            let shown = ModelLibraryPolicy.models(store.models, query: query, filter: filter, downloading: downloading)
                .filter { kind?.matches($0.kind) ?? true }
            let selected = shown.first { $0.id == selectedID }
                ?? shown.first { $0.id == store.status.model } ?? shown.first
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ModelLibraryControls(query: $query, filter: $filter, kind: $kind, compact: compact,
                                             busy: store.busy, models: store.models, downloading: downloading,
                                             importModel: importModel, refresh: { Task { await store.refresh() } })
                        if filter == .downloading {
                            downloads(downloading)
                        } else if shown.isEmpty {
                            ModelLibraryEmpty(query: query, filter: filter, refreshing: store.activity == .refresh,
                                              importModel: importModel, showAll: { query = ""; filter = .all; kind = nil })
                        } else {
                            list(shown, selected: selected, compact: compact)
                        }
                    }
                    .padding(Space.page)
                    .frame(maxWidth: 1160, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .motion(Motion.snappy, value: selected?.id)
                    .motion(Motion.snappy, value: downloading)
                }
                ModelMacFooter(installedCount: store.models.filter(\.installed).count)
            }
            .pageSummary(Fmt.count(store.models.count, "model"))
        }
    }

    @ViewBuilder private func downloads(_ id: String?) -> some View {
        if let id {
            ModelActiveDownload(model: store.models.first { $0.id == id }, id: id, progress: store.downloadProgress,
                                cancelling: store.cancellingDownload, cancel: { store.cancelDownload() })
                .transition(.opacity)
        } else {
            ModelDownloadsEmpty { filter = .all }
        }
    }

    @ViewBuilder private func list(_ shown: [LocalModel], selected: LocalModel?, compact: Bool) -> some View {
        VStack(spacing: 0) {
            ModelLibraryColumnHeading(count: shown.count, compact: compact)
            ForEach(shown) { model in
                ModelLibraryRow(model: model, status: store.status, activity: store.activity,
                                progress: store.downloadProgress, busy: store.busy,
                                selected: selected?.id == model.id, compact: compact,
                                fit: ModelLibraryPolicy.fit(model),
                                select: { selectedID = model.id },
                                perform: { command in Task { await store.perform(command) } })
            }
        }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .cardSurface(padding: 0, tinted: false)
        // A downloadable model not yet on this Mac already has its Download button in the row; the card would hold only "More options".
        if let selected, selected.installed || !selected.downloadable {
            ModelLibrarySelection(model: selected, status: store.status, busy: store.busy,
                                  remove: { removeModel(selected) },
                                  importModel: importModel, chat: { selectModel(selected) })
            .id(selected.id)
            .transition(.opacity)
        }
    }
}
