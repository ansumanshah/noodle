import NoodleCore
import SwiftUI
import UniformTypeIdentifiers

struct ModelsPage: View {
    // Route changes must not interrupt a download, server start, or conversation.
    private static var liveStore: ModelsPageStore?
    private static let demoStore = ModelsPageStore(
        demo: true, demoState: DemoFlags.modelsState ?? (DemoFlags.empty ? .available : .installed))

    /// The one store the pages and the sidebar card share. The live one loads chat history, so it is made on first use.
    static func sharedStore(demo: Bool) -> ModelsPageStore {
        if demo { return demoStore }
        if let liveStore { return liveStore }
        let store = ModelsPageStore(demo: false)
        liveStore = store
        return store
    }

    /// The shared store if something already made it. The sidebar reads download progress through this, so
    /// showing the sidebar never loads chat history on its own.
    static func existingStore(demo: Bool) -> ModelsPageStore? { demo ? demoStore : liveStore }

    let store: ModelsPageStore
    /// Which Models row is showing: Chat, Library or Connections.
    let section: Route
    /// Library's first filter. `--demo-models-tab=downloads` opens it on Downloading.
    var libraryFilter = ModelLibraryFilter.all
    /// Render tests have no window toolbar, so they draw the header inside the page.
    var inlineHeader = false
    /// A hidden window polls nothing; showing it again refreshes.
    var windowVisible = true
    /// Moves to another Models row (Chat after "Use in chat", Library from the Chat welcome).
    var open: (Route) -> Void = { _ in }
    @State private var importing = false
    @State private var removal: LocalModel?
    /// Under this content width the toolbar controls and status shrink so nothing falls into overflow.
    @State private var compact = false
    private static let compactWidth: CGFloat = 640

    init(demo: Bool, section: Route = .chat, windowVisible: Bool = true, open: @escaping (Route) -> Void = { _ in }) {
        self.init(store: Self.sharedStore(demo: demo), section: section,
                  libraryFilter: demo ? DemoFlags.libraryFilter ?? .all : .all)
        self.windowVisible = windowVisible
        self.open = open
    }

    init(store: ModelsPageStore, section: Route = .chat, libraryFilter: ModelLibraryFilter = .all,
         inlineHeader: Bool = false) {
        self.store = store
        self.section = section
        self.libraryFilter = libraryFilter
        self.inlineHeader = inlineHeader
    }

    private var selectedModel: LocalModel? { store.selectedModel }

    private var importDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_MODEL_IMPORT_DIRECTORY"],
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var header: ModelWorkspaceHeader {
        ModelWorkspaceHeader(store: store, selected: selectedModel, select: { store.selectedModelID = $0 }, compact: compact)
    }

    var body: some View {
        VStack(spacing: 0) {
            if inlineHeader, section != .create { header }
            if let problem = store.problem {
                ErrorCard(title: problem.title, detail: problem.detail,
                          action: problem.retry.map { retry in
                              ("Try Again", store.busy, { Task { await store.perform(retry) } })
                          },
                          dismiss: store.dismissProblem)
                    .padding(.horizontal, Space.page).padding(.top, Space.m)
            }
            EmptyView().motion(Motion.standard, value: store.problem?.title)
            Group {
                switch section {
                case .library:
                    ModelLibraryView(store: store, initialFilter: libraryFilter,
                                     importModel: { importing = true }, removeModel: { removal = $0 }) { model in
                        store.selectedModelID = model.id
                        open(.chat)
                    }
                case .connections:
                    ModelConnections(store: store)
                case .create:
                    ModelCreateView(create: ModelCreateStore.shared(models: store), openLibrary: { open(.library) })
                default:
                    ModelPromptPanel(store: store, selectedModel: selectedModel, openLibrary: { open(.library) },
                                     selectModel: { store.selectedModelID = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { compact = $0 }
        .background(WorkspaceStyle.content)
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await store.refreshWhenIdle()
            await store.watchServer()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .folder]) { result in
            Task { await store.finishImport(result) }
        }
        .fileDialogDefaultDirectory(importDirectory)
        .alert("Remove model?", isPresented: $removal.isPresent(),
               presenting: removal) { model in
            Button("Remove", role: .destructive) { Task { await store.perform(.remove(model.id)) } }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This removes the Noodle copy of \(model.name).")
        }
    }
}
