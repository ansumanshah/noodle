import Foundation
import Testing
@testable import NoodleApp

private actor RecoveryService: DockerService {
    private let base = DemoDocker(mode: .empty)
    private(set) var eventStreams = 0
    private(set) var cancelledEvents = 0
    private(set) var statsStreams = 0
    private var pendingListing: CheckedContinuation<[FileEntry], Never>?
    var listingIsPending: Bool { pendingListing != nil }
    func finishListing() {
        pendingListing?.resume(returning: [FileEntry(path: "/slow/old", name: "old", isDirectory: false)])
        pendingListing = nil
    }

    func events() async throws -> AsyncThrowingStream<DockerEvent, Error> {
        eventStreams += 1
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in Task { await self.eventCancelled() } }
        }
    }
    private func eventCancelled() { cancelledEvents += 1 }

    func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error> {
        statsStreams += 1
        let attempt = statsStreams
        return AsyncThrowingStream { continuation in
            continuation.yield(StatsSample(id: 1, cpuPercent: 5, memoryBytes: 10, memoryLimit: 100,
                                          netRx: 0, netTx: 0, pids: 1))
            if attempt == 1 { continuation.finish(throwing: TransportError.closed) }
        }
    }
    func ping() async throws {}
    func info() async throws -> DaemonInfo { try await base.info() }
    func containers() async throws -> [ContainerSummary] { [] }
    func inspect(_ id: String) async throws -> ContainerDetails { try await base.inspect(id) }
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
    func logs(_ id: String, tty: Bool, tail: Int) async throws -> AsyncThrowingStream<LogEntry, Error> {
        try await base.logs(id, tty: tty, tail: tail)
    }
    func exec(_ id: String, argv: [String], timeout: Double) async throws -> DockerAPI.ExecResult {
        try await base.exec(id, argv: argv, timeout: timeout)
    }
    func archive(_ id: String, path: String) async throws -> Data { Data() }
    func list(_ id: String, path: String) async throws -> [FileEntry] {
        if path == "/slow" { return await withCheckedContinuation { pendingListing = $0 } }
        return [FileEntry(path: path + "/current", name: "current", isDirectory: false)]
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct StreamRecoveryTests {
    /// Waits for the condition with no wall-clock deadline of its own: a loaded machine only slows it. A real
    /// hang is caught by the suite's time limit.
    private func until(_ predicate: () async -> Bool) async -> Bool {
        while !(await predicate()) { try? await Task.sleep(for: .milliseconds(2)) }
        return true
    }

    @Test func hidingAHealthyWindowKeepsTheDaemonConnected() async {
        // DemoFlags caches process arguments. Prepare the shared render fixture
        // before this independent demo environment can read those flags.
        _ = RenderHarness.env
        let service = RecoveryService()
        let env = AppEnvironment(service: service, demo: true)
        env.sync.setWindowVisible(true)
        #expect(await until { await service.eventStreams == 1 })
        #expect(env.connection.isUp)
        env.sync.setWindowVisible(false)
        #expect(await until { await service.cancelledEvents == 1 })
        // Allow the cancelled event consumer to finish after stream termination.
        for _ in 0..<20 { await Task.yield() }
        #expect(env.connection.isUp)
        #expect(!env.connection.reconnecting)
    }

    @Test func statsRecoverFromAClosedStreamWithoutAContainerRestart() async {
        let service = RecoveryService(), model = StatsModel()
        let task = Task { await model.run(id: "running", service: service) }
        #expect(await until { model.failure != nil })
        #expect(await until { await service.statsStreams >= 2 && model.failure == nil })
        #expect(model.failure == nil)
        #expect(model.samples.map(\.id) == [1])
        task.cancel()
        await task.value
    }

    @Test func olderFolderResponseCannotReplaceANewerFolder() async {
        let service = RecoveryService(), model = FilesModel()
        await model.open(id: "running", service: service)
        let old = Task { await model.go("/slow") }
        #expect(await until { await service.listingIsPending })
        await model.go("/new")
        await service.finishListing()
        await old.value
        #expect(model.path == "/new")
        #expect(model.entries.map(\.name) == ["current"])
        #expect(!model.loading)
    }

    @Test func cancelledListingDoesNotPublishItsResponse() async {
        let service = RecoveryService(), model = FilesModel()
        await model.open(id: "running", service: service)
        let request = Task { await model.go("/slow") }
        #expect(await until { await service.listingIsPending })
        request.cancel()
        await service.finishListing()
        await request.value
        #expect(model.path == "/")
        #expect(model.entries.map(\.name) == ["current"])
        #expect(model.failure == nil)
    }
}
