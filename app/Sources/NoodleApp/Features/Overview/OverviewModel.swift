import Foundation
import Observation

/// Data the Overview reads while it is on screen: per-container memory from the stats streams the Stats tab
/// uses, exit times of failed containers from `inspect`, and disk numbers. `stop()` cancels all of it.
@MainActor @Observable
final class OverviewModel {
    private(set) var memory: [String: Int] = [:] { didSet { if memory.isEmpty == hasMemory { hasMemory = !memory.isEmpty } } }
    /// Flips only with emptiness, so the page can ask whether to show the card without watching every sample.
    private(set) var hasMemory = false
    /// Container id to the time it last stopped, for exited and dead containers only.
    private(set) var finished: [String: Date] = [:]
    private(set) var disk: OverviewDisk?
    var freed: Int?
    /// Containers whose memory counts: running and paused ones.
    private(set) var tracked = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var bulk: Task<Void, Never>?
    @ObservationIgnored private var bulkIDs: [String] = []
    @ObservationIgnored private var inspections: [String: Task<Void, Never>] = [:]
    /// Containers with a live stream. The rest get one bounded sample at a time.
    static let limit = 16
    private static let batch = 4
    private static let bulkInterval = 30.0

    var total: Int { memory.values.reduce(0, +) }
    /// Shown when the total is missing containers, so it never reads as complete when it is not.
    var uncounted: Int { max(0, tracked - memory.count) }

    // MARK: memory

    /// Follows exactly the given containers. The first sixteen get a stream; any others are sampled once each,
    /// four at a time, every 30 seconds, so the total covers them without a stream apiece.
    func track(_ ids: [String], service: any DockerService, oneShot: @escaping @Sendable (String) async -> Int?) {
        if tracked != ids.count { tracked = ids.count }
        let streamed = Array(ids.prefix(Self.limit)), rest = Array(ids.dropFirst(Self.limit))
        let wanted = Set(streamed), all = Set(ids)
        for id in tasks.keys where !wanted.contains(id) { tasks[id]?.cancel(); tasks[id] = nil }
        memory = memory.filter { all.contains($0.key) }
        for id in streamed where tasks[id] == nil { tasks[id] = stream(id, service: service) }
        guard rest != bulkIDs else { return }
        bulk?.cancel(); bulkIDs = rest
        bulk = rest.isEmpty ? nil : sampleRest(rest, oneShot: oneShot)
    }

    private func stream(_ id: String, service: any DockerService) -> Task<Void, Never> {
        Task { [weak self] in
            // A stream that ends or fails loses its number and reconnects while the page is visible.
            while !Task.isCancelled {
                if let stream = try? await service.stats(id) {
                    do {
                        for try await sample in stream {
                            guard !Task.isCancelled else { return }
                            if self?.memory[id] != sample.memoryBytes { self?.memory[id] = sample.memoryBytes }
                        }
                    } catch {}
                }
                guard !Task.isCancelled else { return }
                if self?.memory[id] != nil { self?.memory[id] = nil }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func sampleRest(_ ids: [String], oneShot: @escaping @Sendable (String) async -> Int?) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                for start in stride(from: 0, to: ids.count, by: Self.batch) {
                    let group = ids[start..<min(start + Self.batch, ids.count)]
                    let results = await withTaskGroup(of: (String, Int?).self) { tasks in
                        for id in group { tasks.addTask { (id, await oneShot(id)) } }
                        var out: [(String, Int?)] = []
                        for await result in tasks { out.append(result) }
                        return out
                    }
                    guard !Task.isCancelled else { return }
                    for (id, bytes) in results where self?.memory[id] != bytes { self?.memory[id] = bytes }
                }
                try? await Task.sleep(for: .seconds(Self.bulkInterval))
            }
        }
    }

    // MARK: exits

    /// One inspect per failure. A container that is no longer exited or dead loses its time, so its next failure
    /// is inspected again instead of showing the last one's. Pass only ids in those two states: a running
    /// container's `FinishedAt` is an earlier run's, or Docker's zero time.
    func learnExits(_ ids: [String], service: any DockerService) {
        let wanted = Set(ids)
        for id in finished.keys where !wanted.contains(id) { finished[id] = nil }
        for (id, task) in inspections where !wanted.contains(id) { task.cancel(); inspections[id] = nil }
        for id in ids where finished[id] == nil && inspections[id] == nil {
            inspections[id] = Task { [weak self] in
                let details = try? await service.inspect(id)
                guard !Task.isCancelled, let self else { return }
                inspections[id] = nil
                if let text = details?.state?.finishedAt, let date = Self.exitDate(text) { finished[id] = date }
            }
        }
    }

    /// Docker reports a container that never stopped as year 1; that is no time at all.
    static func exitDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    // MARK: disk

    func setDisk(_ value: OverviewDisk?) { Motion.animate { disk = value } }

    func stop() {
        for task in tasks.values { task.cancel() }
        for task in inspections.values { task.cancel() }
        bulk?.cancel()
        tasks = [:]; inspections = [:]; bulk = nil; bulkIDs = []
        memory = [:]; tracked = 0
        // Recovery may have happened while hidden. Inspect again when the page becomes visible.
        finished = [:]
    }
}
