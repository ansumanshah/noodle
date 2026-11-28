import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import NoodleAPI

/// Guest containers that bind the Docker socket reach the Docker API, never Noodle's own routes.
@Suite struct RelayRoutingTests {
    private func status(_ method: HTTPMethod, _ uri: String, relayed: Bool) async throws -> Int {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let inbox = ByteInbox(channel: channel)
        inbox.finish()
        var segments = URLParts.segments(URLParts.split(uri: uri).path)
        if let f = segments.first, URLParts.isVersionSegment(f) { segments.removeFirst() }
        let request = Request(method: method, segments: segments, query: [:], headers: [:], apiVersion: APIInfo.apiVersion, body: inbox)
        let parts = PipelineParts(decoder: ByteToMessageHandler(HTTPRequestDecoder()), encoder: HTTPResponseEncoder())
        let writer = ResponseWriter(channel: channel, parts: parts, keepAlive: false, isHead: false,
                                    upgradeRequested: nil)
        var table = RouteTable()
        table.get("_ping") { _, w in try await w.text("OK") }
        table.post("noodle/kubernetes/shared-folders") { _, w in try await w.text("changed") }
        table.get("noodle/model-runner/connection") { _, w in try await w.text("secret") }
        await Router(table: table).serve(request, writer, relayed: relayed)
        var code = 0
        while let part = try await channel.readOutbound(as: HTTPServerResponsePart.self) {
            if case .head(let head) = part { code = Int(head.status.code) }
        }
        _ = try await channel.finish(acceptAlreadyClosed: true)
        return code
    }

    @Test func relayedConnectionsGetDockerAPIButNoNoodleRoutes() async throws {
        #expect(try await status(.GET, "/_ping", relayed: true) == 200)
        #expect(try await status(.POST, "/noodle/kubernetes/shared-folders", relayed: true) == 403)
        #expect(try await status(.POST, "/v1.52/noodle/kubernetes/shared-folders", relayed: true) == 403)
        #expect(try await status(.GET, "/noodle/model-runner/connection", relayed: true) == 403)
        #expect(try await status(.GET, "/%6Eoodle/model-runner/connection", relayed: true) == 403)
        #expect(try await status(.GET, "/noodle/unknown", relayed: true) == 403)
        // Model runner routes delete, pull and run the Mac's models.
        for uri in ["/models", "/models/create", "/engines/unload", "/engines/v1/chat/completions", "/logs",
                    "/exp/vDD4.40/models", "/v1.52/models/x"] {
            #expect(try await status(.DELETE, uri, relayed: true) == 403)
        }
        // The Mac's own socket keeps every route.
        #expect(try await status(.POST, "/noodle/kubernetes/shared-folders", relayed: false) == 200)
        #expect(try await status(.GET, "/_ping", relayed: false) == 200)
        // Docker serves HEAD for every GET route (`HEAD /_ping` is how clients probe the daemon).
        #expect(try await status(.HEAD, "/_ping", relayed: false) == 200)
    }
}
