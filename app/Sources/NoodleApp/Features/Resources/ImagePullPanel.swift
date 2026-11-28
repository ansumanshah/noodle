import SwiftUI

struct ImagePullPanel: View {
    let env: AppEnvironment
    let close: () -> Void
    @State private var reference = ""
    @State private var query = ""
    @State private var results: [ImageSearchResult] = []
    @State private var searching = false
    @State private var searched = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var running = false
    @State private var latest = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Pull Image", systemImage: "arrow.down.circle").font(.headline)
                Spacer()
                Button("Close Pull", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().disabled(running)
            }
            .padding(Space.panel)
            Divider()
            searchSection
                .padding(Space.panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            pullSection.padding(Space.panel)
        }
        .onDisappear { task?.cancel(); searchTask?.cancel() }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search Docker Hub", text: $query)
                    .accessibilityLabel("Search Docker Hub")
                    .onSubmit { search() }
                    .onChange(of: query) {
                        searchTask?.cancel()
                        searching = false
                        searched = false
                        results = []
                        searchError = nil
                    }
                Button("Search") { search() }
                    .disabled(running || searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ImageSearchResults(results: results, searching: searching, searched: searched, error: searchError) { result in
                reference = result.name + ":latest"
            }
        }
        .disabled(running)
    }

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image reference").font(.subheadline.weight(.medium))
            HStack {
                TextField("Image reference", text: $reference, prompt: Text("alpine:latest"))
                    .accessibilityLabel("Image reference")
                    .disabled(running)
                    .onSubmit { start() }
                if running {
                    Button("Cancel Pull") { task?.cancel(); close() }
                } else {
                    Button("Pull") { start() }
                        .buttonStyle(.primaryAction)
                        .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if running {
                HStack { ProgressView().controlSize(.small); Text(latest.isEmpty ? "Pulling image…" : latest).lineLimit(2) }
            }
            if let error { Text(error).foregroundStyle(Status.error).textSelection(.enabled).frame(maxHeight: 120) }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !running else { return }
        searchTask?.cancel()
        results = []
        searchError = nil
        searched = false
        searching = true
        searchTask = Task {
            do {
                let found = try await env.service.searchImages(term)
                guard !Task.isCancelled else { return }
                results = found
                searched = true
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    private func start() {
        let image = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !image.isEmpty else { return }
        searchTask?.cancel()
        searching = false
        running = true
        latest = ""
        error = nil
        let paths = env.paths
        task = Task {
            let docker = await Task.detached { SetupProbe.discovery(paths).docker() }.value
            guard !Task.isCancelled else { return }
            guard let docker else {
                error = "Docker CLI unavailable. Run noodle tools install."
                running = false
                return
            }
            let result = await CLI.stream(executable: docker, ["pull", "--", image],
                                          environment: SetupProbe.dockerEnvironment(socket: paths.socket.path),
                                          timeout: 600) { line in
                Task { @MainActor in if running { latest = line } }
            }
            guard !Task.isCancelled else { return }
            running = false
            if result.code == 0 {
                do { try await env.images.refresh() } catch { env.images.actionError = error.localizedDescription }
                if !Task.isCancelled { close() }
            } else {
                let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                error = message.isEmpty ? "Pull failed (\(result.code))." : String(message.suffix(4096))
            }
        }
    }
}

private struct ImageSearchResults: View {
    let results: [ImageSearchResult]
    let searching: Bool
    let searched: Bool
    let error: String?
    let select: (ImageSearchResult) -> Void

    var body: some View {
        if searching {
            HStack { ProgressView().controlSize(.small); Text("Searching Docker Hub…") }
        } else if let error {
            // The raw error stays in the tooltip for bug reports.
            Text("Couldn’t search Docker Hub. Check your internet connection and search again, or type the image name below.")
                .foregroundStyle(Status.error).help(error)
        } else if searched && results.isEmpty {
            Text("No images found.").foregroundStyle(.secondary)
        } else if !results.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        Button { select(result) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                ImageGlyph(reference: result.name)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(result.name).fontWeight(.medium).lineLimit(1).help(result.name)
                                        if result.isOfficial { Text("Official").font(.caption).foregroundStyle(.secondary).fixedSize() }
                                        Spacer(minLength: 4)
                                        Label(result.starCount.formatted(), systemImage: "star").font(.caption).fixedSize()
                                    }
                                    if !result.description.isEmpty {
                                        Text(result.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(Space.s).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .compactScrollbars()
        }
    }
}
