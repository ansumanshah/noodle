import AppKit
import NoodleCore
import SwiftUI
import UniformTypeIdentifiers

/// Models > Create: one prompt box that makes an image, a voice clip or a video with an installed model.
struct ModelCreateView: View {
    @Bindable var create: ModelCreateStore
    let openLibrary: () -> Void

    var body: some View {
        Group {
            if create.kinds.isEmpty {
                ModelCreateEmpty(create: create, openLibrary: openLibrary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ModelCreateComposer(create: create)
                        if create.memoryShort {
                            ModelMemoryNote(busy: create.running, retry: create.create, dismiss: create.dismissProblem)
                                .padding(.horizontal, -Space.page)
                        }
                        if let problem = create.problem {
                            ErrorCard(title: String(localized: "Couldn’t make this"), detail: problem, dismiss: create.dismissProblem)
                        }
                        if let progress = create.progress { ModelCreateProgress(progress: progress, kind: create.kind) }
                        ModelCreationsGrid(creations: create.creations)
                    }
                    .padding(Space.page)
                    .motion(Motion.standard, value: create.progress != nil)
                    .motion(Motion.standard, value: create.creations.items.map(\.id))
                }
            }
        }
        .onAppear { if let first = create.kinds.first, !create.kinds.contains(create.kind) { create.kind = first } }
    }
}

struct ModelCreateComposer: View {
    @Bindable var create: ModelCreateStore
    @State private var dropTargeted = false

    private var placeholder: String {
        switch create.kind {
        case .image: create.editImage == nil ? String(localized: "Describe a picture") : String(localized: "Describe the change")
        case .speech: String(localized: "Type what the voice should say")
        case .video: String(localized: "Describe a short scene")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                FilterChips(items: create.kinds, selection: $create.kind, title: \.title)
                Spacer(minLength: Space.s)
                let choices = create.installed(create.kind)
                if choices.count > 1 {
                    Picker("Model", selection: Binding(get: { create.model?.id ?? "" }, set: { create.modelID = $0 })) {
                        ForEach(choices) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                } else if let model = create.model {
                    Text(model.name).font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField(placeholder, text: $create.prompt, axis: .vertical)
                .textFieldStyle(.plain).font(.body).lineLimit(3...8)
                .onSubmit(create.create)
                .accessibilityLabel(Text("Prompt"))
            if create.kind == .image, create.editImage != nil {
                Label("Editing the dropped picture", systemImage: "photo")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Start from Nothing") { create.editImage = nil }.buttonStyle(.neutralAction)
            }
            HStack(spacing: Space.s) {
                ModelCreateControls(create: create)
                Spacer(minLength: Space.s)
                if create.running {
                    Button("Stop", systemImage: "stop.fill", action: create.cancel).buttonStyle(.neutralAction)
                } else {
                    Button("Create", systemImage: "wand.and.stars", action: create.create)
                        .buttonStyle(.primaryAction).keyboardShortcut(.return, modifiers: .command)
                        .disabled(create.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .cardSurface()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard create.kind == .image, let url = urls.first, Self.isImage(url),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) ?? .max <= 25 << 20,
                  let data = try? Data(contentsOf: url) else { return false }
            create.editImage = data
            return true
        } isTargeted: { dropTargeted = $0 && create.kind == .image }
        .motion(Motion.snappy, value: create.kind)
    }

    static func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
}

struct ModelCreateControls: View {
    @Bindable var create: ModelCreateStore

    var body: some View {
        switch create.kind {
        case .image:
            if create.editImage == nil {
                Picker("Size", selection: $create.options.size) {
                    ForEach(ModelCreateOptions.sizes, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                }
                .fixedSize()
            }
            Stepper("Steps \(create.options.steps)", value: $create.options.steps, in: 1...50).fixedSize()
            TextField("Seed", value: $create.options.seed, format: .number.grouping(.never), prompt: Text("Random seed"))
                .frame(maxWidth: Control.height * 4)
        case .speech:
            Picker("Voice", selection: $create.options.voice) {
                ForEach(ModelCreateOptions.voices, id: \.self) { Text(ModelCreateControls.voiceName($0)).tag($0) }
            }
            .fixedSize()
        case .video:
            Picker("Length", selection: $create.options.frames) {
                Text("2 seconds").tag(49)
                Text("4 seconds").tag(97)
            }
            .fixedSize()
        }
    }

    /// "af_heart" reads as "Heart (US)".
    static func voiceName(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return id }
        let accent = parts[0].hasPrefix("b") ? "UK" : "US"
        return "\(parts[1].capitalized) (\(accent))"
    }
}

struct ModelCreateProgress: View {
    let progress: ModelCreateStore.Progress
    let kind: ModelCreateKind

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            if let data = progress.preview, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: Control.height * 6, maxHeight: Control.height * 6)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityLabel(Text("Preview"))
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(progress.stage?.capitalized ?? String(localized: "Loading the model")).font(.callout.weight(.medium))
                if let step = progress.step, let total = progress.total, total > 0 {
                    ProgressView(value: Double(step), total: Double(total))
                    Text("Step \(step) of \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
        .cardSurface()
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}
