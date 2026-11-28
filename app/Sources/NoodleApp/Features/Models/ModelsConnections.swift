import AppKit
import NoodleCore
import SwiftUI

struct ModelConnections: View {
    let store: ModelsPageStore
    @State private var example = ModelRequestExample.curl
    @State private var copiedKey = false
    @State private var copiedExample = false

    private var baseURL: URL? { store.status.namedBaseURL ?? store.status.baseURL }
    private var ready: Bool { store.status.phase == .ready }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.page) {
                if ready, let baseURL {
                    serverDetails(baseURL: baseURL)
                    ModelConnectApps(store: store, baseURL: baseURL)
                    requestExample(baseURL: baseURL)
                    if let metrics = store.generationMetrics {
                        ModelConnectionMetrics(metrics: metrics)
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "network").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: Tile.size, height: Tile.size)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: Radius.panel, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.status.phase == .starting ? "Server is starting" : "Server is stopped")
                                .font(.headline)
                            Text("Start a model from the sidebar. Its addresses and key appear here once it is ready.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .cardSurface()
                }
            }
            .frame(maxWidth: 850, alignment: .leading)
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .pageSummary(String(localized: "Use the local server with any app that supports an OpenAI-compatible API."))
        .onChange(of: store.status.model) { copiedKey = false; copiedExample = false }
        .onChange(of: store.status.phase) { copiedKey = false; copiedExample = false }
    }

    private func serverDetails(baseURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Local server", systemImage: "network").font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    ModelStatusDot(color: Status.running)
                    Text("Ready").font(.caption.weight(.medium))
                }
                .foregroundStyle(Status.running)
                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                .background(Status.running.opacity(0.12), in: Capsule())
            }
            ModelEndpointAddress(title: String(localized: "This Mac"), url: baseURL)
            if let workload = store.status.workloadBaseURL {
                ModelEndpointAddress(title: String(localized: "Compose and k3s"), url: workload)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    label("API key")
                    HStack(spacing: 12) {
                        Text("••••••••••••••••••••").font(.callout.monospaced()).accessibilityLabel("API key hidden")
                        Spacer(minLength: 8)
                        Button(copiedKey ? "API Key Copied" : "Copy API Key", systemImage: copiedKey ? "checkmark" : "key") {
                            Task {
                                if let key = await store.connectionKey() {
                                    copyToPasteboard(key, concealed: true)
                                    copiedKey = true
                                }
                            }
                        }
                        .buttonStyle(.neutralAction)
                        .disabled(store.busy)
                    }
                }
                if let id = store.status.model {
                    GridRow {
                        label("Model ID")
                        Text(id).font(.callout.monospaced()).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let backend = store.status.backend {
                    GridRow {
                        label("Runtime")
                        Text(backend.displayName).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("The key stays the same until you rotate it. Copy it into your app’s API key field.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .cardSurface()
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func requestExample(baseURL: URL) -> some View {
        let kind = store.models.first { $0.id == store.status.model }?.kind ?? .chat
        let code = example.code(baseURL: baseURL, model: MLXServeLaunch.modelID(store.status.model ?? "local"), kind: kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Make a request").font(.headline)
                Spacer(minLength: 16)
                Picker("Request language", selection: $example) {
                    ForEach(ModelRequestExample.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            Text("Set NOODLE_API_KEY to the key copied above.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack {
                    Text(example.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedExample ? "Request Copied" : "Copy Request", systemImage: copiedExample ? "checkmark" : "doc.on.doc") {
                        copyToPasteboard(code)
                        copiedExample = true
                    }
                    .buttonStyle(.borderless).hoverFill().font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, Space.panel).padding(.vertical, Space.s)
                .background(Color.secondary.opacity(0.08))
                Divider()
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(Space.panel).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.07))
            }
            .clipShape(.rect(cornerRadius: Radius.panel, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        }
        .cardSurface()
        .onChange(of: example) { copiedExample = false }
    }
}
