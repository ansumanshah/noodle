import SwiftUI

struct BuildsPage: View {
    /// The window's 680 pt minimum leaves 440 pt beside the sidebar. Together these must fit in it, or the
    /// whole page overflows and pushes the sidebar off the left edge.
    static let listMinWidth: CGFloat = 170
    static let detailMinWidth: CGFloat = 240
    let env: AppEnvironment
    @State private var store = BuildsStore()
    @State private var expandedSteps: Set<Int> = []

    private var rows: [AppBuildRecord] {
        let query = env.nav.search
        return store.records.filter {
            ListFilter.matches(query, $0.title, $0.id, $0.status)
        }
    }

    var body: some View {
        @Bindable var model = store
        VStack(spacing: 0) {
            if let error = store.error { ErrorBanner(message: error) { store.error = nil } }
            if store.busy && store.records.isEmpty {
                ProgressView("Loading build history").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.records.isEmpty {
                EmptyState(symbol: "hammer", title: String(localized: "No builds yet"),
                           message: String(localized: "Build an image and Noodle records its steps, cache use and logs here."),
                           command: "docker --context noodle build -t app .")
            } else if rows.isEmpty {
                EmptyState.search(env.nav.search)
            } else {
                HSplitView {
                    ScrollView { LazyVStack(spacing: 2) { ForEach(rows) { record in
                        HStack(spacing: Space.s) {
                            BuildStatusGlyph(status: record.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).lineLimit(1)
                                Text(record.status.capitalized)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .selectableRow(selected: model.selectedID == record.id) { model.selectedID = record.id }
                    } }.padding(Space.s).selectionKeys(rows.map(\.id), selection: $model.selectedID) }
                    .frame(minWidth: Self.listMinWidth, idealWidth: Self.listMinWidth + 30)
                    buildDetail.frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .pageSummary(store.records.isEmpty ? nil : Fmt.count(store.records.count, "build"))
        .task { await store.refresh(demo: env.demo) }
        .task(id: store.selectedID) { expandedSteps = []; await store.inspect(demo: env.demo) }
        .pageActions([PageAction(id: "refresh-builds", title: "Refresh Builds", symbol: "arrow.clockwise",
                                 disabled: store.busy || store.loadingDetail) {
            Task {
                let previousID = store.selectedID
                await store.refresh(demo: env.demo)
                if store.selectedID == previousID { await store.inspect(demo: env.demo) }
            }
        }])
        .motion(Motion.standard, value: store.selectedID)
        .motion(Motion.standard, value: store.busy)
    }

    @ViewBuilder private var buildDetail: some View {
        if store.loadingDetail {
            ProgressView("Loading build details")
        } else if let record = store.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.panel) {
                    HStack(spacing: Space.s) {
                        BuildStatusGlyph(status: record.status)
                        Text(record.title).font(.title2.weight(.semibold)).lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                        GridRow { Text("Status").foregroundStyle(.secondary); Text(record.status.capitalized) }
                        GridRow { Text("ID").foregroundStyle(.secondary); Text(record.id).font(.callout.monospaced()) }
                        GridRow { Text("Started").foregroundStyle(.secondary); Text(record.startedAt) }
                        GridRow { Text("Finished").foregroundStyle(.secondary); Text(record.endedAt ?? "In progress") }
                        GridRow { Text("Duration").foregroundStyle(.secondary); Text("\(record.duration, format: .number.precision(.fractionLength(2))) s").monospacedDigit() }
                        GridRow { Text("Cache").foregroundStyle(.secondary); Text("\(record.cachedSteps) of \(record.totalSteps) steps cached") }
                        GridRow { Text("Context").foregroundStyle(.secondary); Text(Fmt.bytes(Int(record.contextSize))) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .box()
                    if let error = record.error { Text(error).foregroundStyle(Status.error) }
                    if !store.steps.isEmpty {
                        Text("Steps").font(.headline)
                        ForEach(store.steps) { step in
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedSteps.contains(step.id) },
                                set: { if $0 { expandedSteps.insert(step.id) } else { expandedSteps.remove(step.id) } }
                            )) {
                                Text(step.output.joined(separator: "\n"))
                                    .font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, Space.xxs)
                            } label: {
                                HStack {
                                    Text("#\(step.id) \(step.title.isEmpty ? "Step" : step.title)").lineLimit(2)
                                    Spacer()
                                    Text([step.status, step.duration].compactMap { $0 }.joined(separator: " · "))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Build log").font(.headline)
                    Text(record.log.flatMap { $0.isEmpty ? nil : $0 } ?? "No log was captured.")
                        .font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        .box(padding: Space.m)
                }
                .textSelection(.enabled)
                .padding(Space.page)
            }
        } else {
            EmptyState(symbol: "hammer", title: String(localized: "Select a build"), message: "", compact: true)
        }
    }
}

/// Success is green, failure red, anything still running neutral.
private struct BuildStatusGlyph: View {
    let status: String
    var body: some View {
        let lower = status.lowercased()
        let (symbol, tint): (String, Color) = lower.contains("fail") || lower.contains("error")
            ? ("xmark.circle.fill", Status.error)
            : lower.contains("success") || lower.contains("complete") ? ("checkmark.circle.fill", Status.running) : ("circle.dotted", .secondary)
        Image(systemName: symbol).foregroundStyle(tint).imageScale(.medium).accessibilityHidden(true)
    }
}
