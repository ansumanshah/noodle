import Foundation
import Synchronization
import Testing
@testable import NoodleApp

private actor OverviewService: DockerService {
    private var finish = "2026-11-07T10:00:00Z"
    private var holdInspect = false
    private var inspectWaiter: CheckedContinuation<Void, Never>?
    private var inspectionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var inspections = 0
    private(set) var streams = 0
    private(set) var samples = 0
    private(set) var concurrentSamples = 0
    private(set) var peakSamples = 0

    /// Returns once `inspect` has been entered `count` times. Signalled by the call itself, not by a clock.
    func waitForInspections(_ count: Int) async {
        if inspections >= count { return }
        await withCheckedContinuation { inspectionWaiters.append((count, $0)) }
    }

    func setFinish(_ value: String) { finish = value }
    func holdInspection() { holdInspect = true }
    func releaseInspection() { inspectWaiter?.resume(); inspectWaiter = nil; holdInspect = false }
    func inspect(_ id: String) async throws -> ContainerDetails {
        inspections += 1
        let ready = inspectionWaiters.filter { $0.count <= inspections }
        inspectionWaiters.removeAll { $0.count <= inspections }
        for waiter in ready { waiter.continuation.resume() }
        if holdInspect { await withCheckedContinuation { inspectWaiter = $0 } }
        return try JSONDecoder().decode(ContainerDetails.self,
            from: Data(#"{"Id":"\#(id)","State":{"FinishedAt":"\#(finish)"}}"#.utf8))
    }

    func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error> {
        streams += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(StatsSample(id: 1, cpuPercent: 0, memoryBytes: 10, memoryLimit: 100,
                                          netRx: 0, netTx: 0, pids: 1))
        }
    }

    func sample(_ id: String) async -> Int? {
        samples += 1; concurrentSamples += 1
        peakSamples = max(peakSamples, concurrentSamples)
        await Task.yield()
        concurrentSamples -= 1
        return 20
    }

    func ping() async throws {}
    func info() async throws -> DaemonInfo { fatalError("Unexpected info") }
    func containers() async throws -> [ContainerSummary] { [] }
    func images() async throws -> [ImageSummary] { [] }
    func volumes() async throws -> [VolumeSummary] { [] }
    func networks() async throws -> [NetworkSummary] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func restart(_ id: String) async throws {}
    func removeContainer(_ id: String) async throws {}
    func removeImage(_ id: String) async throws {}
    func removeVolume(_ name: String) async throws {}
    func removeNetwork(_ id: String) async throws {}
    func events() async throws -> AsyncThrowingStream<DockerEvent, Error> { fatalError("Unexpected events") }
    func logs(_ id: String, tty: Bool, tail: Int) async throws -> AsyncThrowingStream<LogEntry, Error> { fatalError("Unexpected logs") }
    func exec(_ id: String, argv: [String], timeout: Double) async throws -> DockerAPI.ExecResult { fatalError("Unexpected exec") }
    func archive(_ id: String, path: String) async throws -> Data { Data() }
    func list(_ id: String, path: String) async throws -> [FileEntry] { [] }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct OverviewModelTests {
    /// Suspends until the condition holds, resuming on each change to the observable state it reads.
    /// No deadline: a hang is caught by the suite's time limit, and a slow machine only takes longer.
    private func until(_ ready: @MainActor @escaping () -> Bool) async {
        while !ready() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = ready() } onChange: { continuation.resume() }
            }
        }
    }

    @Test func memoryIncludesContainersBeyondSixteenWithBoundedReads() async {
        let service = OverviewService(), model = OverviewModel()
        defer { model.stop() }
        model.track((0..<25).map(String.init), service: service) { await service.sample($0) }
        #expect(model.uncounted == 25)
        await until { model.memory.count == 25 }
        #expect(model.total == 16 * 10 + 9 * 20)
        #expect(model.uncounted == 0)
        #expect(await service.streams == 16)
        #expect(await service.samples == 9)
        #expect(await service.peakSamples <= 4)
        model.stop()
        #expect(model.memory.isEmpty && model.tracked == 0)
    }

    @Test func failedBulkReadsNeverClaimACompleteTotal() async {
        let service = OverviewService(), model = OverviewModel()
        defer { model.stop() }
        let attempts = Mutex(0)
        model.track((0..<18).map(String.init), service: service) { _ in attempts.withLock { $0 += 1 }; return nil }
        await until { model.memory.count == 16 }
        try? await waitUntil { attempts.withLock { $0 } >= 2 }
        #expect(model.total == 160)
        #expect(model.uncounted == 2)
    }

    @Test func stoppingDiscardsExitTimeSoAHiddenRestartCanBeInspected() async throws {
        let service = OverviewService(), model = OverviewModel()
        defer { model.stop() }
        model.learnExits(["api"], service: service)
        await until { model.finished["api"] != nil }
        let first = try #require(model.finished["api"])
        model.stop()
        #expect(model.finished.isEmpty)
        await service.setFinish("2026-11-07T12:00:00Z")
        model.learnExits(["api"], service: service)
        await until { model.finished["api"] != nil }
        let second = try #require(model.finished["api"])
        #expect(second > first)
        #expect(await service.inspections == 2)
    }

    @Test func cancelledInspectionCannotPublishAfterHiding() async {
        let service = OverviewService(), model = OverviewModel()
        await service.holdInspection()
        model.learnExits(["api"], service: service)
        await service.waitForInspections(1)
        model.stop()
        await service.releaseInspection()
        model.learnExits(["other"], service: service)
        await until { model.finished["other"] != nil }
        #expect(model.finished["api"] == nil)
        model.stop()
    }
}
