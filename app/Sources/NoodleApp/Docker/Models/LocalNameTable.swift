import Foundation
import NoodleCore

/// The names the daemon serves (`GET /noodle/names`), keyed by container so rows can show `web.localhost`.
struct LocalNameTable: Equatable, Sendable {
    struct Entry: Equatable, Sendable { var host: String; var containerID: String }
    var port = 80
    var entries: [Entry] = []

    /// The first name of a running container, with the URL that opens it. Plain http: it works before the local CA is trusted.
    func link(for container: ContainerSummary) -> (host: String, url: URL)? {
        guard container.state == "running",
              let host = entries.first(where: { !$0.containerID.isEmpty && container.id.hasPrefix($0.containerID) })?.host,
              let url = URL(string: "http://\(host)\(port == 80 ? "" : ":\(port)")") else { return nil }
        return (host, url)
    }

    static func decode(_ data: Data) -> LocalNameTable {
        struct Reply: Decodable {
            struct Name: Decodable { var host: String; var containerID: String }
            var enabled: Bool?
            var port: Int?
            var names: [Name]?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), r.enabled != false else { return LocalNameTable() }
        return LocalNameTable(port: r.port ?? 80, entries: (r.names ?? []).map { Entry(host: $0.host, containerID: $0.containerID) })
    }
}

extension DockerAPI {
    func modelConnection() async throws -> ModelRunnerConnection {
        let r = try await socket.request("GET", "/noodle/model-runner/connection", timeout: 5)
        guard r.status == 200 else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
        return try JSONDecoder().decode(ModelRunnerConnection.self, from: r.body)
    }

    /// An older daemon without the route, or any failure, simply means no names.
    func localNames() async throws -> LocalNameTable {
        let r = try await socket.request("GET", "/noodle/names", timeout: 3)
        return r.status == 200 ? LocalNameTable.decode(r.body) : LocalNameTable()
    }
}
