import Foundation
import NIOCore
import NIOHTTP1
import NoodleCore
import NoodleEngine

/// Binds every Docker route to an Engine call. Handlers are split by area in `Routes+*.swift`.
struct Handlers: Sendable {
    let engine: Engine
    /// Opens the model endpoint for containers. Nil in tests that build routes without the model server.
    var modelConnection: (@Sendable () async throws -> ModelRunnerConnection)?

    func routes(modelRunner: DockerModelRunner? = nil) -> RouteTable {
        var t = RouteTable()
        systemRoutes(&t)
        modelRunnerRoutes(&t, runner: modelRunner)
        devRoutes(&t)
        finderRoutes(&t)
        publicLinkRoutes(&t)
        containerRoutes(&t)
        containerEditRoutes(&t)
        streamRoutes(&t)
        execRoutes(&t)
        imageRoutes(&t)
        networkRoutes(&t)
        volumeRoutes(&t)
        return t
    }

    // MARK: - shared helpers

    static func filters(_ req: Request) -> Filters { Filters.parse(req.string("filters")) }

    /// Parsed filters, refused with 400 when a key is not one Docker's list endpoint accepts.
    static func filters(_ req: Request, allowed: Set<String>) throws -> Filters {
        let f = filters(req)
        if let bad = f.firstUnknownKey(allowed: allowed) { throw EngineError.badRequest("Invalid filter '\(bad)'") }
        if let bad = f.firstInvalidLabel() { throw EngineError.badRequest("Invalid filter 'label=\(bad)': empty label key") }
        return f
    }

    static let jsonStream = "application/json"

    func notSwarm() async throws {
        throw APIError(status: 503, message: "This node is not a swarm manager. Use \"docker swarm init\" or \"docker swarm join\" to connect this node to swarm and try again.")
    }

    /// Docker progress line: `{"status","id","progressDetail":{current,total}}`.
    struct ProgressLine: Encodable {
        struct Detail: Encodable { var current: Int64?; var total: Int64? }
        var status: String
        var id: String?
        var progressDetail: Detail
    }

    struct ErrorLine: Encodable {
        struct Detail: Encodable { var message: String }
        var errorDetail: Detail
        var error: String
    }

    static func progressLine(_ e: ProgressEvent) -> ProgressLine {
        ProgressLine(status: e.status, id: e.id, progressDetail: .init(current: e.current, total: e.total))
    }

    /// Stream progress events as Docker JSON lines. Errors before the first event become a normal HTTP error.
    func streamProgress(_ events: AsyncThrowingStream<ProgressEvent, Error>, _ w: ResponseWriter) async throws {
        do {
            for try await e in events {
                if !w.started { try await w.beginStream(contentType: Self.jsonStream) }
                try await w.writeJSON(Self.progressLine(e), terminator: "\r\n")
            }
            if !w.started { try await w.beginStream(contentType: Self.jsonStream) }
        } catch {
            if !w.started { throw error }
            if error is CancellationError || error is ConnectionClosed { throw error }
            let (_, msg) = ErrorMap.describe(error)
            try? await w.writeJSON(ErrorLine(errorDetail: .init(message: msg), error: msg), terminator: "\r\n")
        }
    }
}
