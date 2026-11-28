import Foundation
import NoodleCore

/// Everything the UI needs from a daemon. `DockerAPI` is the live implementation over the socket,
/// `DemoDocker` serves canned data for `--demo`.
protocol DockerService: Sendable {
    func ping() async throws
    func info() async throws -> DaemonInfo
    func vmStatus() async throws -> VMReadiness?
    func containers() async throws -> [ContainerSummary]
    func localNames() async throws -> LocalNameTable
    /// Where containers reach the local model (`host.docker.internal` plus a private key), from the engine.
    func modelConnection() async throws -> ModelRunnerConnection
    func inspect(_ id: String) async throws -> ContainerDetails
    func imageHistory(_ id: String) async throws -> [ImageHistory]
    func images() async throws -> [ImageSummary]
    func searchImages(_ term: String) async throws -> [ImageSearchResult]
    func volumes() async throws -> [VolumeSummary]
    func networks() async throws -> [NetworkSummary]
    func start(_ id: String) async throws
    func stop(_ id: String) async throws
    func restart(_ id: String) async throws
    func removeContainer(_ id: String) async throws
    func removeImage(_ id: String) async throws
    func removeVolume(_ name: String) async throws
    func removeNetwork(_ id: String) async throws
    func events() async throws -> AsyncThrowingStream<DockerEvent, Error>
    func logs(_ id: String, tty: Bool, tail: Int) async throws -> AsyncThrowingStream<LogEntry, Error>
    func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error>
    func statsSnapshot(_ id: String) async throws -> StatsSample?
    func exec(_ id: String, argv: [String], timeout: Double) async throws -> DockerAPI.ExecResult
    func archive(_ id: String, path: String) async throws -> Data
    /// The same tar as `archive`, in chunks, so a caller can stop early or write to disk without holding it all.
    func archiveStream(_ id: String, path: String) async throws -> AsyncThrowingStream<Data, Error>
    func list(_ id: String, path: String) async throws -> [FileEntry]
}

extension DockerAPI: DockerService {}

extension DockerService {
    func archiveStream(_ id: String, path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let whole = try await archive(id, path: path)
        return AsyncThrowingStream { $0.yield(whole); $0.finish() }
    }
    func vmStatus() async throws -> VMReadiness? { nil }
    func localNames() async throws -> LocalNameTable { LocalNameTable() }
    func modelConnection() async throws -> ModelRunnerConnection { throw HTTPFailure(status: 404, message: "No model address") }
    func imageHistory(_ id: String) async throws -> [ImageHistory] { [] }
    func searchImages(_ term: String) async throws -> [ImageSearchResult] { [] }
    func statsSnapshot(_ id: String) async throws -> StatsSample? { nil }
}

struct VMReadiness: Decodable, Sendable {
    struct Usage: Decodable, Sendable {
        let cpus: Int
        let memoryMiB: Int
        let memoryUsed: UInt64?
        let cpuBusy: UInt64?
        let cpuTotal: UInt64?

        func percent(since previous: Usage) -> Int? {
            guard let cpuBusy, let cpuTotal, let oldBusy = previous.cpuBusy, let oldTotal = previous.cpuTotal,
                  cpuBusy >= oldBusy, cpuTotal > oldTotal else { return nil }
            let total = cpuTotal - oldTotal
            let busy = min(cpuBusy - oldBusy, total)
            return Int((100 * Double(busy) / Double(total)).rounded())
        }
    }

    let state: String
    let vmRunning: Bool
    let guestAgentReady: Bool
    var cpus: Int?
    var memoryMiB: Int?
    var bootCount: Int?
    var usage: Usage?

    var memoryLimitBytes: Int? {
        guard let mib = usage?.memoryMiB ?? memoryMiB, mib > 0, mib <= Int.max >> 20 else { return nil }
        return mib << 20
    }

    var label: String? {
        switch state {
        case "starting" where vmRunning && !guestAgentReady: "Connecting to Linux…"
        case "starting": "Starting VM…"
        case "stopping": "Stopping VM…"
        default: nil // A stopped VM is normal when idle; unknown states remain unobtrusive.
        }
    }
}

struct ImageSearchResult: Decodable, Sendable, Identifiable {
    let name: String
    let description: String
    let starCount: Int
    let isOfficial: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description
        case starCount = "star_count"
        case isOfficial = "is_official"
    }
}
