import SwiftUI

/// Chat header: who answers (assistant menu) and the per-chat Advanced settings.
struct ModelAssistantMenu: View {
    let store: ModelsPageStore
    let manage: () -> Void
    var selectModel: (String) -> Void = { _ in }
    /// Narrow header: the person icon alone, the name stays in the help text.
    var compact = false
    @State private var note: String?

    private var current: ModelAssistant { store.assistants.assistant(store.chat.current?.assistantID) }

    var body: some View {
        Menu {
            ForEach(store.assistants.all) { assistant in
                Button {
                    store.chat.configure(assistantID: assistant.id, settings: store.chat.current?.settings)
                    note = nil
                    if let model = assistant.modelID {
                        if store.models.first(where: { $0.id == model })?.installed == true { selectModel(model) } else {
                            note = String(localized: "\(assistant.name) prefers \(model), which isn't installed. Get it from Library, or keep chatting with the current model.")
                        }
                    }
                } label: {
                    if assistant.id == current.id { Label(assistant.name, systemImage: "checkmark") } else { Text(assistant.name) }
                }
            }
            Divider()
            Button("Manage assistants…", action: manage)
        } label: {
            Label(current.name, systemImage: "person.crop.circle")
                .labelStyle(CompactTitleStyle(compact: compact))
                .font(.callout.weight(.semibold)).lineLimit(1)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .padding(.horizontal, compact ? Space.s : Space.m).controlSurface()
        .fixedSize()
        .disabled(store.busy)
        .popover(isPresented: $note.isPresent(), arrowEdge: .bottom) {
            Text(note ?? "").font(.callout).padding(Space.m).frame(width: 260)
        }
        .help(compact ? "\(current.name). Choose who answers in this chat" : "Choose who answers in this chat")
        .accessibilityIdentifier("models-assistant-menu")
    }
}

struct ModelChatSettingsButton: View {
    let store: ModelsPageStore
    @State private var shown = false

    var body: some View {
        Button("Chat settings", systemImage: "slider.horizontal.3") { shown.toggle() }
            .labelStyle(.iconOnly).buttonStyle(.iconAction)
            .help("Settings for this chat")
            .popover(isPresented: $shown, arrowEdge: .bottom) { ModelChatSettingsView(store: store) }
    }
}

struct ModelChatSettingsView: View {
    let store: ModelsPageStore
    @State private var advanced = false

    private var settings: ModelChatSettings { store.chat.current?.settings ?? .init() }
    private func set(_ change: (inout ModelChatSettings) -> Void) {
        var updated = settings
        change(&updated)
        store.chat.configure(assistantID: store.chat.current?.assistantID, settings: updated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Toggle("Think before answering", isOn: Binding(get: { settings.thinking ?? false },
                                                           set: { value in set { $0.thinking = value ? true : nil } }))
                .help("Slower, and can help with harder questions")
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Text("Creativity")
                        Spacer()
                        Text(settings.temperature.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? String(localized: "Default"))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(get: { settings.temperature ?? 0.7 }, set: { value in set { $0.temperature = value } }),
                           in: 0...2, step: 0.1)
                        .accessibilityLabel("Temperature")
                    field("Longest reply (tokens)", \.maxTokens, limit: ModelChatSettings.maxTokensLimit)
                    field("History kept (tokens)", \.contextLength, limit: ModelChatSettings.contextLengthLimit)
                    Text("Leave a field empty to use what the model suggests. History kept only trims what the app sends.").font(.caption).foregroundStyle(.secondary)
                    Button("Use defaults") { set { $0 = .init() } }.disabled(settings.isDefault)
                }
                .padding(.top, Space.s)
            }
        }
        .padding(Space.m).frame(width: 280)
        .motion(Motion.snappy, value: advanced)
    }

    private func field(_ title: LocalizedStringKey, _ key: WritableKeyPath<ModelChatSettings, Int?>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            TextField("Default", value: Binding(get: { settings[keyPath: key] },
                                                set: { value in set { $0[keyPath: key] = value.flatMap { $0 > 0 ? min($0, limit) : nil } } }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }
}

/// Add, edit and delete assistants. Changes save as you type.
struct ModelAssistantsSheet: View {
    let store: ModelsPageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ModelAssistant.defaultID

    private var assistants: ModelAssistantStore { store.assistants }
    private var selected: ModelAssistant { assistants.assistant(selection) }

    private var modelOptions: [PickerOption] {
        var options = [PickerOption(id: "", label: String(localized: "Keep the current model"))]
        options += store.chatModels.map { PickerOption(id: $0.id, label: $0.installed ? $0.name : "\($0.name) (not installed)") }
        if let stale = selected.modelID, !store.models.contains(where: { $0.id == stale }) {
            options.append(PickerOption(id: stale, label: "\(stale) (not installed)"))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(assistants.all, selection: $selection) { Text($0.name).lineLimit(1).tag($0.id) }
                    Divider()
                    HStack {
                        Button("Add assistant", systemImage: "plus") { selection = assistants.add().id }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).hoverFill()
                        Spacer()
                    }.padding(8)
                }
                .frame(width: 170)
                Divider()
                form.padding(Space.m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack { Spacer(); Button("Done") { assistants.flush(); dismiss() }.buttonStyle(.primaryAction).keyboardShortcut(.defaultAction) }.padding(Space.s)
        }
        .frame(width: 560, height: 380)
    }

    @ViewBuilder private var form: some View {
        if selected.isBuiltIn {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Default").font(.headline)
                Text("Answers with no special instructions. Add your own assistant to give the model a role.")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                TextField("Name", text: binding(\.name)).textFieldStyle(.roundedBorder)
                Text("Instructions").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: binding(\.instructions)).font(.body)
                    .frame(minHeight: 120).overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color.secondary.opacity(0.3)))
                LabeledContent("Model") {
                    SearchablePicker(title: String(localized: "Model"), options: modelOptions,
                                     selection: Binding(get: { selected.modelID ?? "" },
                                                        set: { value in update { $0.modelID = value.isEmpty ? nil : value } }))
                }
                Spacer(minLength: 0)
                Button("Delete assistant", role: .destructive) {
                    let id = selection
                    selection = ModelAssistant.defaultID
                    assistants.delete(id)
                }
            }
        }
    }

    private func update(_ change: (inout ModelAssistant) -> Void) {
        var assistant = selected
        change(&assistant)
        assistants.update(assistant)
    }

    private func binding(_ key: WritableKeyPath<ModelAssistant, String>) -> Binding<String> {
        Binding(get: { selected[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }
}

private struct CompactTitleStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { Label(configuration) }
    }
}
