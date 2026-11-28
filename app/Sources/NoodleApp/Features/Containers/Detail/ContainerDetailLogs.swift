import SwiftUI

struct LogsTab: View {
    let env: AppEnvironment
    let sources: [(id: String, label: String?)]
    /// Restarts the stream when the containers or their states change.
    let key: String
    @State private var model = LogsModel()
    @AppStorage("logFontSize") private var fontSize = 12.0
    @AppStorage("logTimestamps") private var showTimes = true
    @FocusState private var findFocused: Bool

    init(env: AppEnvironment, container: ContainerSummary) {
        self.env = env; sources = [(container.id, nil)]; key = "\(container.id)-\(container.state)"
    }

    /// A project's containers merged into one log.
    init(env: AppEnvironment, project: ComposeProjectInfo) {
        self.env = env
        sources = project.containers.map { ($0.id, $0.service ?? $0.name) }
        key = project.containers.map { "\($0.id)-\($0.state)" }.joined(separator: ",")
    }

    private var levelTitle: String {
        switch model.minLevel {
        case nil: "All Levels"
        case .info?: "Info and Up"
        case .warn?: "Warnings and Up"
        default: "Errors Only"
        }
    }

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    SearchField(prompt: String(localized: "Filter logs"), text: $m.query, focus: $findFocused)
                    MenuPicker(title: "Level", value: levelTitle, selection: $m.minLevel) {
                        Text("All Levels").tag(LogLevel?.none)
                        Text("Info and Up").tag(LogLevel?.some(.info))
                        Text("Warnings and Up").tag(LogLevel?.some(.warn))
                        Text("Errors Only").tag(LogLevel?.some(.error))
                    }
                }
                HStack {
                    Text("\(model.visible.count) of \(model.total) lines").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Button("Follow", systemImage: m.follow ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line") { m.follow.toggle() }
                        .labelStyle(.iconOnly).buttonStyle(.iconAction).help("Follow new output").accessibilityValue(m.follow ? "On" : "Off").accessibilityAddTraits(m.follow ? .isSelected : [])
                    Button("Copy All", systemImage: "doc.on.doc") {
                        copyToPasteboard(model.plainText)
                    }.buttonStyle(.neutralAction).help("Copy all visible lines (respects the filter). Select lines to copy part of it with Command-C.")
                        .disabled(model.visible.isEmpty)
                    Button("Clear", systemImage: "trash") { model.clear() }.labelStyle(.iconOnly).buttonStyle(.iconAction).help("Clear")
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            Divider()
            logBody
        }
        .background { Button("Find") { findFocused = true }.keyboardShortcut("f", modifiers: [.command, .option]).hidden() }
        .task(id: "\(key)-\(env.connection.isUp)-\(env.sync.windowVisible)") {
            // A hidden window streams nothing; showing it again reloads the tail.
            if env.connection.isUp && env.sync.windowVisible { await model.run(sources: sources, service: env.service) }
        }
    }

    @ViewBuilder private var logBody: some View {
        if let f = model.failure, model.total == 0 {
            EmptyState(symbol: "exclamationmark.triangle.fill", title: String(localized: "Couldn’t read logs"), message: f, compact: true)
        } else if model.total == 0 && !env.connection.isUp {
            EmptyState(symbol: "text.alignleft", title: String(localized: "Waiting for Noodle"), message: String(localized: "Logs resume when the engine reconnects."), compact: true)
        } else if model.total == 0 {
            if model.streaming { EmptyState(symbol: "text.alignleft", title: String(localized: "No output yet"), message: String(localized: "New lines appear here as the container writes them."), compact: true) }
            else { LoadingState(label: String(localized: "Loading logs…")) }
        } else if model.visible.isEmpty {
            EmptyState.search(model.query.isEmpty ? "this level" : model.query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { e in
                            LogLine(entry: e, query: model.query, size: fontSize, showTime: showTimes).id(e.id)
                        }
                    }
                    .padding(.vertical, Space.xs)
                    .textSelection(.enabled)
                }
                .compactScrollbars()
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.visible.last?.id) { _, last in
                    if model.follow, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear { if let last = model.visible.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }
}

struct LogLine: View, Equatable {
    let entry: LogEntry
    let query: String
    let size: Double
    let showTime: Bool

    nonisolated private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if showTime {
                Text(entry.time.map { Self.time.string(from: $0) } ?? "        ")
                    .foregroundStyle(.tertiary)
            }
            Text(attributed).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: size, design: .monospaced))
        .padding(.horizontal, Space.panel).padding(.vertical, 1)
        .background(entry.level == .error ? Status.error.opacity(0.07) : .clear)
    }

    private var color: Color {
        switch entry.level { case .error: Status.error; case .warn: Status.warning; case .debug: .secondary; case .info: .primary }
    }
    private var attributed: AttributedString {
        var a = AttributedString(entry.text)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            var from = a.startIndex
            while let r = a[from...].range(of: q, options: .caseInsensitive) {
                a[r].backgroundColor = .yellow.opacity(0.45)
                a[r].foregroundColor = .black
                from = r.upperBound
            }
        }
        return a
    }
}
