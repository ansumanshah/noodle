import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import NoodleAPI

/// File replies stream in chunks but keep one Content-Length reply with the exact byte range.
@Suite struct SendFileTests {
    @Test func streamsTheRangeInChunksWithContentLength() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sendfile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        let parts = PipelineParts(decoder: ByteToMessageHandler(HTTPRequestDecoder()), encoder: HTTPResponseEncoder())
        let writer = ResponseWriter(channel: channel, parts: parts, keepAlive: true, isHead: false, upgradeRequested: nil)
        let offset = 7, count = (2 << 20) + 5
        try await writer.sendFile(url, offset: Int64(offset), count: Int64(count), contentType: "application/octet-stream",
                                  headers: [("X-Test", "1")])
        var head: HTTPResponseHead?
        var body = Data()
        var chunks = 0
        var ended = false
        while let part = try await channel.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let h): head = h
            case .body(.byteBuffer(let b)): body.append(contentsOf: b.readableBytesView); chunks += 1
            case .body: Issue.record("unexpected body kind")
            case .end: ended = true
            }
        }
        #expect(head?.status == .ok)
        #expect(head?.headers["Content-Length"] == [String(count)])
        #expect(head?.headers["Content-Type"] == ["application/octet-stream"])
        #expect(head?.headers["X-Test"] == ["1"])
        #expect(body == bytes[offset..<(offset + count)])
        #expect(chunks > 1)
        #expect(ended)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
}
