import SwiftUI
import Charts

struct StatsTab: View {
    let env: AppEnvironment
    let container: ContainerSummary
    @State private var model = StatsModel()

    var body: some View {
        Group {
            if !container.isRunning {
                EmptyState(symbol: "chart.xyaxis.line", title: String(localized: "Not running"), message: String(localized: "Stats are live, so they only exist while the container runs."), compact: true)
            } else if !env.connection.isUp {
                EmptyState(symbol: "chart.xyaxis.line", title: String(localized: "Waiting for Noodle"), message: String(localized: "Stats resume when the engine reconnects."), compact: true)
            } else if let failure = model.failure {
                EmptyState(symbol: "exclamationmark.triangle.fill", title: String(localized: "Stats disconnected"), message: failure, compact: true)
            } else if model.samples.isEmpty {
                LoadingState(label: String(localized: "Waiting for first sample…"))
            } else {
                ScrollView {
                    let s = model.latest!
                    VStack(alignment: .leading, spacing: 12) {
                        Card(title: String(localized: "CPU"), symbol: "cpu", minHeight: 150) {
                            bigNumber(Fmt.percent(s.cpuPercent))
                            spark(model.samples, value: { $0.cpuPercent }, tint: WorkspaceStyle.accent)
                        }
                        Card(title: String(localized: "Memory"), symbol: "memorychip", minHeight: 150) {
                            bigNumber(Fmt.bytes(s.memoryBytes))
                            Text("of \(Fmt.bytes(s.memoryLimit))").font(.callout).foregroundStyle(.secondary)
                            spark(model.samples, value: { Double($0.memoryBytes) / 1_048_576 }, tint: WorkspaceStyle.accent)
                        }
                        Card(title: String(localized: "Network"), symbol: "network", minHeight: 130) {
                            HStack(spacing: 18) {
                                VStack(alignment: .leading) { Text("Received").font(.callout).foregroundStyle(.secondary); bigNumber(Fmt.bytes(s.netRx)) }
                                VStack(alignment: .leading) { Text("Sent").font(.callout).foregroundStyle(.secondary); bigNumber(Fmt.bytes(s.netTx)) }
                            }
                            Text("\(Fmt.bytes(Int(model.netRxRate)))/s in · \(Fmt.bytes(Int(model.netTxRate)))/s out")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Card(title: String(localized: "Processes"), symbol: "list.number", minHeight: 130) {
                            bigNumber("\(s.pids) processes")
                            spark(model.samples, value: { Double($0.pids) }, tint: WorkspaceStyle.accent)
                        }
                    }
                    .padding(Space.page)
                }
            }
        }
        .task(id: "\(container.id)-\(container.state)-\(env.connection.isUp)") {
            if container.isRunning && env.connection.isUp { await model.run(id: container.id, service: env.service) }
        }
    }

    private func bigNumber(_ s: String) -> some View {
        Text(s).font(.title3.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            .motion(Motion.snappy, value: s)
    }

    private func spark(_ samples: [StatsSample], value: @escaping (StatsSample) -> Double, tint: Color) -> some View {
        Chart(samples) { s in
            AreaMark(x: .value("t", s.id), y: .value("v", value(s))).foregroundStyle(tint.opacity(0.18)).interpolationMethod(.monotone)
            LineMark(x: .value("t", s.id), y: .value("v", value(s))).foregroundStyle(tint).interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...max(1, (samples.map(value).max() ?? 1) * 1.25))
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}
