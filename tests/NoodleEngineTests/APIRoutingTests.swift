import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NoodleCore
import NoodleEngine
import Testing
@testable import NoodleAPI

@Suite("RequestSeconds")
struct RequestSecondsTests {
    @Test func secondsRejectsNonFiniteAndHugeValues() {
        func seconds(_ v: String) -> Int64? {
            Request(method: .GET, segments: [], query: ["since": [v]], headers: [:], apiVersion: APIInfo.apiVersion,
                    body: ByteInbox(channel: EmbeddedChannel())).seconds("since")
        }
        for bad in ["nan", "inf", "-inf", "1e20"] { #expect(seconds(bad) == nil) }
        #expect(seconds("1700000000.5") == 1_700_000_000)
    }
}

@Suite("APIRouting")
struct APIRoutingTests {
    private func router() -> Router {
        var t = RouteTable()
        let noop: Handler = { _, _ in }
        t.get("containers/{id}/json", noop)
        t.get("containers/json", noop)
        t.get("images/*name/json", noop)
        t.get("images/json", noop)
        t.post("containers/{id}/start", noop)
        return Router(table: t)
    }

    /// Mirrors HTTPHandler.begin: decode segments, then strip a leading version segment.
    private func route(_ method: HTTPMethod, _ uri: String) -> [String: String]? {
        var segs = URLParts.segments(URLParts.split(uri: uri).path)
        if let f = segs.first, URLParts.isVersionSegment(f) { segs.removeFirst() }
        return router().find(method, segs)?.1
    }

    @Test func matchesTable() {
        #expect(route(.GET, "/containers/abc/json") == ["id": "abc"])
        #expect(route(.GET, "/containers/json") == [:])
        #expect(route(.POST, "/containers/abc/start") == ["id": "abc"])
        #expect(route(.GET, "/containers/abc/start") == nil)
        #expect(route(.GET, "/nope") == nil)
        #expect(route(.GET, "/containers/abc/json/extra") == nil)
    }

    @Test func restBacktracks() {
        #expect(route(.GET, "/images/alpine/json") == ["name": "alpine"])
        #expect(route(.GET, "/images/library/alpine/json") == ["name": "library/alpine"])
        #expect(route(.GET, "/images/host:5000/a/b/json") == ["name": "host:5000/a/b"])
        // An image literally called "json" still reaches the inspect route.
        #expect(route(.GET, "/images/json/json") == ["name": "json"])
        #expect(route(.GET, "/images//json") == [:])   // empty segments are dropped
    }

    @Test func versionPrefix() {
        #expect(route(.GET, "/v1.52/images/alpine/json") == ["name": "alpine"])
        #expect(route(.GET, "/v1.52/containers/json") == [:])
        // "v1" as an image name is not at the front, so it is a name, not a version.
        #expect(route(.GET, "/images/v1/json") == ["name": "v1"])
        #expect(route(.GET, "/v1.52/images/v1/json") == ["name": "v1"])
        #expect(URLParts.isVersionSegment("v1.52"))
        #expect(!URLParts.isVersionSegment("v"))
        #expect(!URLParts.isVersionSegment("version"))
        #expect(!URLParts.isVersionSegment("images"))
    }

    @Test func percentDecoding() {
        #expect(URLParts.segments("/images/a%20b/json") == ["images", "a b", "json"])
        // An encoded slash never adds a segment, and it never lands inside an {id} param.
        #expect(URLParts.segments("/containers/a%2Fb/json") == ["containers", "a/b", "json"])
        #expect(route(.GET, "/containers/a%2Fb/json") == nil)
        #expect(route(.GET, "/containers/..%2Fjson/json") == nil)
        // Image names may carry the slash.
        #expect(route(.GET, "/images/library%2Falpine/json") == ["name": "library/alpine"])
    }

    @Test(arguments: ["grpc", "session", "probe"])
    func nativeAdapterProbeAndFailureUseOnlyInjectedResources(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-build-route-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing-adapter.tar.gz")
        let manifest: [String: Any] = ["buildkit": ["version": "0.2.0", "url": missing.absoluteString,
            "size": 1, "sha256": String(repeating: "0", count: 64)]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("on-demand.json"))
        let paths = NoodlePaths(root: root.appendingPathComponent("home"), resources: resources)
        let adapter = BuildKitAdapter(paths: paths, environment: [:], executableURL: nil)
        let handlers = Handlers(engine: Engine(paths: paths))
        let channel = NIOAsyncTestingChannel()
        do {
            // This testing channel performs no socket IO or VM work.
            try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
            let parts = PipelineParts(decoder: ByteToMessageHandler(HTTPRequestDecoder()), encoder: HTTPResponseEncoder())
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandlers([parts.decoder, parts.encoder])
            }.get()
            let writer = ResponseWriter(channel: channel, parts: parts, keepAlive: false, isHead: false,
                                        upgradeRequested: "h2c")
            let endpoint = mode == "probe" ? "grpc" : mode
            let request = Request(method: .POST, segments: [endpoint], query: [:], headers: ["Upgrade": "h2c"],
                                  apiVersion: APIInfo.apiVersion, body: ByteInbox(channel: channel))
            var table = RouteTable()
            table.post(endpoint) { req, writer in
                try await handlers.nativeBuildConnection(req, writer, mode: endpoint, adapter: adapter)
            }
            let task = Task { await Router(table: table).serve(request, writer) }
            let head = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
            let header = String(decoding: head.readableBytesView, as: UTF8.self)
            if mode == "session" {
                await task.value
                #expect(header.contains("500 Internal Server Error"))
                var body = Data()
                while let bytes = try await channel.readOutbound(as: ByteBuffer.self) { body.append(contentsOf: bytes.readableBytesView) }
                let json = try JSONDecoder().decode([String: String].self, from: body)
                #expect(json["message"]?.contains(missing.absoluteString) == true)
            } else {
                #expect(header.contains("101 UPGRADED"))
                #expect(!FileManager.default.fileExists(atPath: Tools.directory(paths).path))
                if mode == "probe" {
                    try await channel.close().get()
                    await task.value
                    #expect(!FileManager.default.fileExists(atPath: Tools.directory(paths).path))
                } else {
                    var request = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
                    request += [0, 0, 0, 4, 0, 0, 0, 0, 0] // SETTINGS
                    request += [0, 0, 1, 1, 4, 0, 0, 0, 1, 0x88] // HEADERS, stream 1
                    try await channel.writeInbound(channel.allocator.buffer(bytes: request))
                    await task.value
                    var frames: [UInt8] = []
                    while let bytes = try await channel.readOutbound(as: ByteBuffer.self) { frames += bytes.readableBytesView }
                    #expect(Array(frames.prefix(18)) == [0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0]) // SETTINGS, ACK
                    #expect(frames[21] == 1 && frames[22] == 5 && frames[26] == 1) // HEADERS, END_STREAM, stream 1
                    let block = String(decoding: frames.dropFirst(27), as: UTF8.self)
                    #expect(block.contains("grpc-status"))
                    #expect(block.contains(missing.absoluteString))
                    #expect(block.contains("noodle tools install buildkit"))
                }
            }
            _ = try await channel.finish(acceptAlreadyClosed: true)
        } catch {
            _ = try? await channel.finish(acceptAlreadyClosed: true)
            throw error
        }
    }
}

@Suite("HTTPHandlerLifetime")
struct HTTPHandlerLifetimeTests {
    /// A closed connection must free its handler; a handler that keeps its context alive leaks per connection.
    @Test func closedConnectionReleasesHandler() throws {
        weak var released: HTTPHandler?
        try {
            let channel = EmbeddedChannel()
            let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
            let parts = PipelineParts(decoder: decoder, encoder: HTTPResponseEncoder())
            let handler = HTTPHandler(router: Router(table: RouteTable()), parts: parts, connections: HTTPConnections())
            parts.handler = handler
            try channel.pipeline.syncOperations.addHandlers([parts.decoder, parts.encoder, handler])
            released = handler
            _ = try channel.finish()
        }()
        #expect(released == nil)
    }
}
