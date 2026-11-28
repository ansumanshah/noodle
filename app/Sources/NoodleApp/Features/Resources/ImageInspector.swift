import AppKit
import SwiftUI

enum ImageTab: String, CaseIterable, Identifiable {
    case info = "Info", layers = "Layers", security = "Security"
    var id: String { rawValue }
}

struct ImageInspector: View {
    let env: AppEnvironment
    let image: ImageSummary
    var initialTab: ImageTab = .info
    let close: () -> Void
    @State private var tab: ImageTab?
    @State private var layers: [ImageLayerRow]?
    @State private var layerFailure: String?
    @State private var showRun = false

    private var shown: ImageTab { tab ?? initialTab }
    private var users: [ContainerSummary] {
        env.containers.items.filter { container in
            if !container.imageID.isEmpty { return container.imageID == image.id }
            return image.repoTags.contains(container.image) || container.image == image.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ImageGlyph(reference: image.displayName)
                    Text(image.displayName).font(.headline).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Close Details", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                }
                ChipTabBar(tabs: ImageTab.allCases, selection: Binding(get: { shown }, set: { tab = $0 }),
                           title: \.rawValue, compact: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("View")
            }.padding(Space.panel)
            Divider()
            Group {
                switch shown {
                case .info: ScrollView { info.padding(Space.panel).frame(maxWidth: .infinity, alignment: .leading) }
                case .layers:
                    ImageLayersTab(rows: layers ?? [], loading: layers == nil, failure: layerFailure)
                        .task { await loadLayers() }
                case .security: ImageSecurityTab(env: env, image: image)
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .motion(Motion.snappy, value: shown)
    }

    private func loadLayers() async {
        guard layers == nil || layerFailure != nil else { return }
        async let catalog = CatalogImageLayer.load(image.id, demo: env.demo)
        var history: [ImageHistory] = []
        var failure: String?
        do { history = try await env.service.imageHistory(image.id) }
        catch { failure = error.localizedDescription }
        let rows = await ImageLayerRow.merge(history: history, catalog: catalog)
        guard !Task.isCancelled else { return }
        layers = rows
        layerFailure = rows.isEmpty ? failure : nil
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text(Fmt.bytes(image.size)).monospacedDigit() }
                GridRow { Text("Created").foregroundStyle(.secondary); Text(Fmt.ago(image.created)) }
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(image.shortID).font(.callout.monospaced()).textSelection(.enabled)
                        Button("Copy ID", systemImage: "doc.on.doc") {
                            copyToPasteboard(image.id)
                        }.labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill().help("Copy the full image ID")
                    }
                }
            }
            section("Tags") {
                if image.repoTags.isEmpty { Text("Untagged").foregroundStyle(.secondary) }
                ForEach(image.repoTags, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
            }
            section("Containers") {
                if users.isEmpty { Text("No container uses this image.").foregroundStyle(.secondary) }
                ForEach(users) { container in
                    Button(container.name) { env.nav.open(container: container.id) }.buttonStyle(.link)
                }
            }
            if showRun {
                ImageRunForm(env: env, image: image) { showRun = false }
            } else {
                Button("Run Image", systemImage: "play.fill") { showRun = true }.disabled(env.demo)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
