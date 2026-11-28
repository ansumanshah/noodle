import SwiftUI

struct FilesTab: View {
    let env: AppEnvironment
    let container: ContainerSummary
    @State private var model = FilesModel()
    @State private var showingPreview = false

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            if !container.isRunning {
                EmptyState(symbol: "folder.badge.questionmark", title: String(localized: "Start the container to browse files"),
                           message: String(localized: "Browsing runs a command inside the container."), compact: true)
            } else if !env.connection.isUp {
                EmptyState(symbol: "folder", title: String(localized: "Waiting for Noodle"),
                           message: String(localized: "Files reload when the engine reconnects."), compact: true)
            } else if let f = model.failure, model.entries.isEmpty {
                EmptyState(symbol: "exclamationmark.triangle.fill", title: String(localized: "Can’t list this folder"), message: f, compact: true)
            } else if !model.loading && model.entries.isEmpty {
                EmptyState(symbol: "folder", title: String(localized: "This folder is empty"), message: String(localized: "There are no entries to show."), compact: true)
            } else {
                if showingPreview, model.selectedEntry != nil {
                    PreviewPane(model: model) { showingPreview = false }
                } else {
                    VStack(spacing: 0) {
                        List(selection: $m.selection) {
                            ForEach(model.entries) { e in
                                Label(e.name, systemImage: e.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(.primary)
                                    .symbolRenderingMode(.hierarchical)
                                    .tag(e.id)
                                    .listRowSeparator(.hidden)
                                    .contextMenu { entryMenu(e) }
                            }
                        }
                        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                            if let id = ids.first, let e = model.entries.first(where: { $0.id == id }) {
                                if e.isDirectory { Task { await model.go(e.path) } }
                                else { showingPreview = true }
                            }
                        }
                        .overlay { if model.loading && model.entries.isEmpty { ProgressView() } }
                        if let entry = model.selectedEntry {
                            Divider()
                            HStack {
                                Text(entry.name).lineLimit(1).foregroundStyle(.secondary)
                                Spacer()
                                if entry.isDirectory {
                                    Button("Open", systemImage: "folder") { Task { await model.go(entry.path) } }
                                }
                                Button("Preview", systemImage: "eye") { showingPreview = true }
                            }
                            .font(.callout).padding(.horizontal, Space.m).padding(.vertical, Space.s)
                        }
                    }
                }
            }
        }
        .task(id: "\(container.id):\(container.state):\(env.connection.isUp)") {
            showingPreview = false
            guard container.isRunning, env.connection.isUp else { return }
            await model.open(id: container.id, service: env.service)
        }
        .onChange(of: model.path) { _, _ in showingPreview = false }
        .overlay(alignment: .top) {
            if let failure = model.failure, !model.entries.isEmpty {
                ErrorBanner(message: failure) { model.clearFailure() }
            }
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                Text(n).font(.callout).padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                    .background(WorkspaceStyle.sidebar, in: .capsule).padding(Space.m).transition(.slide(from: .bottom))
                    .task(id: n) { try? await Task.sleep(for: .seconds(3)); model.clearNotice() }
            }
        }
        .motion(Motion.snappy, value: model.notice)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { i, c in
                        if i > 1 { Text("/").font(.subheadline.monospaced()).foregroundStyle(.secondary) }
                        Button(c.name) { Task { await model.go(c.path) } }
                            .buttonStyle(.borderless).hoverFill().font(.callout.monospaced())
                            .foregroundStyle(i == model.crumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button("Up", systemImage: "arrow.up") {
                let parent = (model.path as NSString).deletingLastPathComponent
                Task { await model.go(parent.isEmpty ? "/" : parent) }
            }
            .labelStyle(.iconOnly).disabled(model.path == "/").help("Enclosing folder")
        }
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
        .disabled(!container.isRunning || !env.connection.isUp)
    }

    @ViewBuilder private func entryMenu(_ e: FileEntry) -> some View {
        if e.isDirectory { Button("Open", systemImage: "folder") { Task { await model.go(e.path) } } }
        Button("Save to Downloads", systemImage: "arrow.down.circle") { Task { await model.saveToDownloads(e) } }
        Button("Show in Finder", systemImage: "magnifyingglass") { Task { await model.showInFinder(e) } }
        Button("Copy Path", systemImage: "doc.on.doc") { copyToPasteboard(e.path) }
    }
}

struct PreviewPane: View {
    let model: FilesModel
    let back: () -> Void
    var body: some View {
        Group {
            if let e = model.selectedEntry {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("Back to Files", systemImage: "arrow.left", action: back).help("Back to files")
                        Image(systemName: e.isDirectory ? "folder.fill" : "doc.text").foregroundStyle(.secondary)
                        Text(e.name).font(.headline).lineLimit(1)
                        Spacer()
                        Button("Save to Downloads", systemImage: "arrow.down.circle") { Task { await model.saveToDownloads(e) } }
                        Button("Show in Finder", systemImage: "magnifyingglass") { Task { await model.showInFinder(e) } }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                    .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
                    Divider()
                    content
                }
            } else {
                EmptyState(symbol: "doc.viewfinder", title: String(localized: "No file selected"), message: String(localized: "Select a file to preview it.\nDouble-click a folder to open it."), compact: true)
            }
        }
        .motion(Motion.standard, value: model.preview)
    }

    @ViewBuilder private var content: some View {
        switch model.preview {
        case .none, .loading: LoadingState(label: String(localized: "Reading…"))
        case .directory: EmptyState(symbol: "folder", title: String(localized: "Folder"), message: String(localized: "Double-click to open. Save to Downloads exports it as a .tar."), compact: true)
        case .binary(let n): EmptyState(symbol: "doc.zipper", title: String(localized: "No preview"), message: String(localized: "Binary file, \(Fmt.bytes(n)). Save it to Downloads to open it."), compact: true)
        case .failed(let s): EmptyState(symbol: "exclamationmark.triangle.fill", title: String(localized: "Couldn’t read file"), message: s, compact: true)
        case .text(let s, let truncated):
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(s).font(.callout.monospaced()).textSelection(.enabled)
                    if truncated { Text("Preview truncated at 256 KB").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(Space.panel)
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
