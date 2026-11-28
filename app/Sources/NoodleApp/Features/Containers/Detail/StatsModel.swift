import Foundation
import Observation
import AppKit

@MainActor @Observable
final class StatsModel {
    private(set) var samples: [StatsSample] = []
    private(set) var failure: String?
    var latest: StatsSample? { samples.last }

    func run(id: String, service: any DockerService) async {
        samples = []; failure = nil
        while !Task.isCancelled {
            do {
                var firstSample = true
                for try await s in try await service.stats(id) {
                    try Task.checkCancellation()
                    // Transport sample IDs restart at one for every new stream.
                    if firstSample { samples = []; firstSample = false }
                    failure = nil
                    samples.append(s)
                    if samples.count > 90 { samples.removeFirst(samples.count - 90) }
                }
                try Task.checkCancellation()
                failure = "Stats stream closed. Reconnecting…"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    var netRxRate: Double { rate(\.netRx) }
    var netTxRate: Double { rate(\.netTx) }
    private func rate(_ kp: KeyPath<StatsSample, Int>) -> Double {
        guard samples.count >= 2 else { return 0 }
        let a = samples[samples.count - 2][keyPath: kp], b = samples[samples.count - 1][keyPath: kp]
        return Double(max(0, b - a))
    }
}
