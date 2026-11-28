import NoodleCore
import SwiftUI

extension ModelMemoryFit {
    var label: LocalizedStringKey {
        switch self {
        case .good: "Runs well"
        case .tight: "Tight on memory"
        case .tooBig: "Too big for this Mac"
        }
    }
}

struct ModelLibraryRow: View {
    let model: LocalModel
    let status: LocalModelStatus
    let activity: ModelsPageStore.Activity?
    let progress: LocalModelPullProgress?
    let busy: Bool
    let selected: Bool
    let compact: Bool
    var fit: ModelMemoryFit?
    let select: () -> Void
    let perform: (ModelsPageStore.Command) -> Void
    @State private var hovering = false

    private var state: ModelLibraryPolicy.State {
        ModelLibraryPolicy.state(model: model, status: status, activity: activity, progress: progress)
    }

    /// Plain words only; the runtime and file format live under More options in the detail card.
    private var subtitle: String {
        if state == .running { return "Running" }
        if model.installed { return model.downloadable ? "On this Mac" : "Imported" }
        return model.downloadable ? "Ready to download" : "Import needed"
    }

    /// Chat models need no label; the others are served as API only.
    private var kindLabel: String? {
        switch model.kind {
        case .chat: nil
        case .embeddings: "Embeddings"
        case .speechToText: "Speech to text"
        case .textToSpeech: "Text to speech"
        case .imageGeneration: "Image generation"
        case .videoGeneration: "Video generation"
        }
    }

    /// "Ready to download · Runs well": the fit part alone takes the warning tint.
    private var statusLine: Text {
        var line = Text((compact ? "\(subtitle) · \(ModelLibraryPolicy.size(model.bytes))" : subtitle) + (kindLabel.map { " · " + $0 } ?? ""))
        if let fit {
            line = line + Text(" · ") + Text(fit.label).foregroundStyle(fit == .tight ? Status.warning : .secondary)
        }
        return line
    }

    var body: some View {
        HStack(spacing: ModelLibraryColumns.spacing) {
            Button(action: select) {
                HStack(spacing: ModelLibraryColumns.spacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        statusLine.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact {
                        Text(ModelLibraryPolicy.size(model.bytes)).font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: ModelLibraryColumns.size, alignment: .trailing)
                    }
                }
                .padding(.vertical, Space.m).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.name), \(state.rawValue), \(ModelLibraryPolicy.size(model.bytes))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("Show details for \(model.name)")
            ModelLibraryRowAction(model: model, state: state, status: status, busy: busy, perform: perform)
                .frame(width: ModelLibraryColumns.status(compact: compact), alignment: .trailing)
        }
        .padding(.horizontal, Space.panel)
        .rowHover(hovering, selected: selected)
        .onHover { hovering = $0 }
    }
}

private struct ModelLibraryRowAction: View {
    let model: LocalModel
    let state: ModelLibraryPolicy.State
    let status: LocalModelStatus
    let busy: Bool
    let perform: (ModelsPageStore.Command) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            switch state {
            case .running:
                Button("Stop", systemImage: "stop.fill") { perform(.stop) }
                    .buttonStyle(ControlButtonStyle(tint: Status.stopped)).disabled(busy)
            case .installed:
                Button("Start", systemImage: "play.fill") { perform(.start(model.id)) }
                    .buttonStyle(ControlButtonStyle(tint: Status.running))
                    .disabled(busy || status.phase != .stopped)
                    .help(status.phase == .stopped ? "Start \(model.name)" : "Stop the running model before starting another")
            case .available:
                Button("Download", systemImage: "arrow.down") { perform(.download(model.id)) }
                    .buttonStyle(.neutralAction).disabled(busy)
            default:
                HStack(spacing: 5) {
                    if state != .importNeeded { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Text(state.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ModelLibrarySelection: View {
    let model: LocalModel
    let status: LocalModelStatus
    let busy: Bool
    let remove: () -> Void
    let importModel: () -> Void
    let chat: () -> Void
    @State private var moreOptions = false

    private var inUse: Bool { status.model == model.id && status.phase != .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.name).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if model.backend == .mlx, !inUse {
                Label {
                    Text("The first start sets up what this model needs. Allow a few GB of free disk space.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "info.circle") }
                .font(.callout).foregroundStyle(.secondary)
            }
            if !model.downloadable {
                Text(model.installed ? "Imported from your own model files."
                     : "Import the original model file or folder to use this model.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.installed || !model.downloadable {
            HStack(spacing: 10) {
                if model.installed {
                    Button("Use in Chat", systemImage: "bubble.left.and.bubble.right", action: chat)
                        .buttonStyle(.primaryAction)
                        .disabled(busy)
                    Spacer()
                    Button("Remove", systemImage: "trash", action: remove)
                        .buttonStyle(.neutralAction)
                        .disabled(busy || inUse)
                        .help(inUse ? "Stop the model before removing its files"
                              : "Remove the Noodle copy of this model")
                } else if !model.downloadable {
                    Button("Import Model", systemImage: "square.and.arrow.down", action: importModel)
                        .buttonStyle(.neutralAction).disabled(busy)
                }
            }
            }
            // A plain toggle, not a disclosure arrow: engine detail stays out of the way until asked for.
            Button(moreOptions ? "Hide options" : "More options") { moreOptions.toggle() }
                .buttonStyle(.link).font(.callout)
            if moreOptions {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Runtime", value: model.backend.displayName)
                    LabeledContent("Format", value: model.backend == .mlx ? "MLX" : "GGUF")
                    LabeledContent("Model ID") {
                        Text(model.id).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .motion(Motion.snappy, value: moreOptions)
        .cardSurface()
    }
}
