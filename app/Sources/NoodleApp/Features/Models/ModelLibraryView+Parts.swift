import Foundation
import NoodleCore
import SwiftUI

struct ModelMacFooter: View {
    let installedCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer").accessibilityHidden(true)
            let memory = ProcessInfo.processInfo.physicalMemory.formatted(.byteCount(style: .memory))
            Text("This Mac has \(memory) of memory")
            Spacer(minLength: 8)
            Text("\(installedCount) installed").monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Space.page)
        .frame(height: Control.height)
        .accessibilityElement(children: .combine)
    }
}

/// Narrows the library to one kind of model. Chat models need no chip: they are the default.
enum ModelKindFilter: String, CaseIterable, Identifiable {
    case embeddings = "Embeddings", speech = "Speech", image = "Images", video = "Video"
    var id: Self { self }

    func matches(_ kind: LocalModelKind) -> Bool {
        switch self {
        case .embeddings: kind == .embeddings
        case .speech: kind.isSpeech
        case .image: kind == .imageGeneration
        case .video: kind == .videoGeneration
        }
    }
}

struct ModelLibraryControls: View {
    @Binding var query: String
    @Binding var filter: ModelLibraryFilter
    @Binding var kind: ModelKindFilter?
    let compact: Bool
    let busy: Bool
    let models: [LocalModel]
    let downloading: String?
    let importModel: () -> Void
    let refresh: () -> Void
    @Namespace private var chipSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Control.gap) {
                SearchField(prompt: String(localized: "Search models"), text: $query)
                if !compact {
                    Button("Import Model", systemImage: "square.and.arrow.down", action: importModel)
                        .buttonStyle(.neutralAction).disabled(busy)
                }
                Button("Refresh Models", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly).buttonStyle(.iconAction).help("Refresh models and server status").disabled(busy)
            }
            WrapRow {
                let counts = self.counts
                ForEach(ModelLibraryFilter.allCases) { item in chip(item, count: counts[item] ?? 0) }
                if models.contains(where: { $0.kind != .chat }) {
                    // A Layout lays Divider out horizontally, so draw the vertical rule directly.
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 14)
                    ForEach(ModelKindFilter.allCases) { item in
                        FilterChip(title: item.rawValue, count: models.filter { item.matches($0.kind) }.count,
                                   selected: kind == item, namespace: chipSpace) { kind = kind == item ? nil : item }
                    }
                }
                if compact {
                    Button("Import", systemImage: "square.and.arrow.down", action: importModel)
                        .buttonStyle(.neutralAction).disabled(busy)
                }
            }
        }
        .motion(Motion.snappy, value: filter)
        .motion(Motion.snappy, value: kind)
    }

    private var counts: [ModelLibraryFilter: Int] {
        Dictionary(uniqueKeysWithValues: ModelLibraryFilter.allCases.map { filter in
            (filter, ModelLibraryPolicy.models(models, query: query, filter: filter, downloading: downloading).count)
        })
    }

    private func chip(_ item: ModelLibraryFilter, count: Int) -> some View {
        FilterChip(title: item.rawValue, count: count, selected: filter == item, namespace: chipSpace) { filter = item }
    }
}

struct ModelLibraryColumnHeading: View {
    let count: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: ModelLibraryColumns.spacing) {
            Text("Model · \(count)").frame(maxWidth: .infinity, alignment: .leading)
            if !compact { Text("Size").frame(width: ModelLibraryColumns.size, alignment: .trailing) }
            Text("Status").frame(width: ModelLibraryColumns.status(compact: compact), alignment: .trailing)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
    }
}

struct ModelLibraryEmpty: View {
    let query: String
    let filter: ModelLibraryFilter
    let refreshing: Bool
    let importModel: () -> Void
    let showAll: () -> Void

    var body: some View {
        Group {
            if refreshing {
                LoadingState(label: String(localized: "Looking up models…"))
            } else if !query.isEmpty || filter != .all {
                EmptyState(symbol: query.isEmpty ? "square.stack.3d.up" : "magnifyingglass",
                           title: query.isEmpty ? "No models here yet" : "No matching models",
                           message: query.isEmpty ? "Download one from All and it shows up here." : "Try another name.",
                           action: (String(localized: "Show All Models"), false, showAll))
            } else {
                EmptyState(symbol: "square.stack.3d.up", title: String(localized: "No models yet"),
                           message: String(localized: "Check your connection and refresh, or bring your own model file."),
                           action: (String(localized: "Import Model"), false, importModel))
            }
        }
        .frame(minHeight: 300)
    }
}
