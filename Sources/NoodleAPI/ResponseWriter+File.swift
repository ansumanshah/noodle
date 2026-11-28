import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - file replies

extension ResponseWriter {
    /// Send `count` bytes of `url` starting at `offset` as one complete reply, read in chunks off the event loop.
    func sendFile(_ url: URL, offset: Int64, count: Int64, contentType: String, headers: [(String, String)] = []) async throws {
        var file: FileHandle?
        if count > 0 {
            file = try FileHandle(forReadingFrom: url)
            try file?.seek(toOffset: UInt64(offset))
        }
        defer { try? file?.close() }
        try transition(from: .idle, to: .done)
        try checkOpen()
        var h = baseHeaders(contentType: contentType)
        for (k, v) in headers { h.add(name: k, value: v) }
        h.replaceOrAdd(name: "Content-Length", value: String(max(count, 0)))
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: h)), promise: nil)
        var left = isHead ? 0 : count
        while left > 0, let file {
            let size = Int(min(left, 1 << 20))
            let data = try await NIOThreadPool.singleton.runIfActive { try file.read(upToCount: size) ?? Data() }
            // The file shrank after Content-Length went out: the reply cannot complete, so drop the connection.
            guard !data.isEmpty else { channel.close(promise: nil); throw ConnectionClosed() }
            left -= Int64(data.count)
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))).get()
        }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    }
}
