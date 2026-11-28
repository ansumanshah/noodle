import SwiftUI

struct PickerOption: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Type-to-filter rule for long pickers: case and diacritic insensitive, blank shows everything.
enum PickerFilter {
    static func filter(_ options: [PickerOption], query: String) -> [PickerOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return options }
        return options.filter { $0.label.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Arrow-key step clamped to the list, so holding a key stops at the ends.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(index + delta, 0), count - 1)
    }
}

/// A menu-style picker that opens a filter field. Up and Down move, Return picks, Escape closes.
/// Lists of 10 or fewer keep the plain menu `Picker`.
struct SearchablePicker: View {
    let title: String
    let options: [PickerOption]
    @Binding var selection: String
    @State private var open = false
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    var body: some View {
        if options.count <= 10 {
            Picker(title, selection: $selection) { ForEach(options) { Text($0.label).tag($0.id) } }
                .labelsHidden().pickerStyle(.menu)
        } else {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Text(options.first { $0.id == selection }?.label ?? title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(title)
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
        }
    }

    private var list: some View {
        let shown = PickerFilter.filter(options, query: query)
        return VStack(spacing: 0) {
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder).padding(Space.s)
                .focused($focused)
                .onSubmit { if shown.indices.contains(highlight) { pick(shown[highlight]) } }
                .onKeyPress(.upArrow) { highlight = PickerFilter.step(highlight, by: -1, count: shown.count); return .handled }
                .onKeyPress(.downArrow) { highlight = PickerFilter.step(highlight, by: 1, count: shown.count); return .handled }
                .onKeyPress(.escape) { open = false; return .handled }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, option in
                            Button { pick(option) } label: {
                                HStack {
                                    Text(option.label).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if option.id == selection { Image(systemName: "checkmark") }
                                }
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                                .contentShape(Rectangle())
                                .background(index == highlight ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: Radius.control))
                            }
                            .buttonStyle(.plain).id(option.id)
                        }
                        if shown.isEmpty { Text("No matches").foregroundStyle(.secondary).padding(Space.s) }
                    }
                }
                .onChange(of: highlight) { _, new in if shown.indices.contains(new) { proxy.scrollTo(shown[new].id) } }
            }
        }
        .frame(width: 280, height: min(320, CGFloat(shown.count) * 28 + 60))
        .onChange(of: query) { highlight = max(PickerFilter.filter(options, query: query).firstIndex { $0.id == selection } ?? 0, 0) }
        .onAppear { query = ""; highlight = options.firstIndex { $0.id == selection } ?? 0; focused = true }
    }

    private func pick(_ option: PickerOption) {
        selection = option.id
        open = false
    }
}
