import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NoodleEngine

/// One response. Exactly one of: a complete reply, a chunked stream, or a hijack.
public final class ResponseWriter: @unchecked Sendable {
    enum State { case idle, streaming, done, hijacked }
    let channel: Channel
    let parts: PipelineParts
    let isHead: Bool
    let upgradeRequested: String?
    /// Called on the event loop when a hijacked connection goes inactive; cancels the request task.
    var onDisconnect: (@Sendable () -> Void)?
    private let lock = NIOLock()
    private var _state = State.idle
    private var _keepAlive: Bool

    init(channel: Channel, parts: PipelineParts, keepAlive: Bool, isHead: Bool, upgradeRequested: String?) {
        self.channel = channel; self.parts = parts; self._keepAlive = keepAlive; self.isHead = isHead
        self.upgradeRequested = upgradeRequested
    }

    var state: State { lock.withLock { _state } }
    var keepAlive: Bool { lock.withLock { _keepAlive } }
    public var started: Bool { state != .idle }

    func transition(from: State, to: State) throws {
        try lock.withLock {
            guard _state == from else { throw APIError(status: 500, message: "response already started") }
            _state = to
        }
    }

    static var dockerHeaders: HTTPHeaders {
        HTTPHeaders([("Api-Version", APIInfo.apiVersion), ("Docker-Experimental", "false"), ("Ostype", "linux"),
                     ("Server", "Noodle/\(APIInfo.serverVersion) (darwin)")])
    }

    func baseHeaders(contentType: String?) -> HTTPHeaders {
        var h = Self.dockerHeaders
        h.add(name: "Date", value: HTTPDate.now())
        if let contentType { h.add(name: "Content-Type", value: contentType) }
        if !keepAlive { h.add(name: "Connection", value: "close") }
        return h
    }

    func checkOpen() throws { guard channel.isActive else { throw ConnectionClosed() } }

    // MARK: - complete replies

    public func send(_ status: HTTPResponseStatus, contentType: String? = nil, headers: [(String, String)] = [], body: ByteBuffer? = nil) async throws {
        try transition(from: .idle, to: .done)
        try checkOpen()
        var h = baseHeaders(contentType: contentType)
        for (k, v) in headers { h.add(name: k, value: v) }
        let bodiless = status.code == 204 || status.code == 304 || status.code < 200
        if !bodiless { h.replaceOrAdd(name: "Content-Length", value: String(body?.readableBytes ?? 0)) }
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: h)), promise: nil)
        if let body, body.readableBytes > 0, !bodiless, !isHead {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    }

    public func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok, headers: [(String, String)] = []) async throws {
        let data = try JSONOut.encode(value)
        try await send(status, contentType: "application/json", headers: headers, body: ByteBuffer(bytes: data))
    }

    public func text(_ s: String, status: HTTPResponseStatus = .ok, contentType: String = "text/plain; charset=utf-8", headers: [(String, String)] = []) async throws {
        try await send(status, contentType: contentType, headers: headers, body: channel.allocator.buffer(string: s))
    }

    public func empty(_ status: HTTPResponseStatus = .noContent, headers: [(String, String)] = []) async throws {
        try await send(status, headers: headers)
    }

    func sendError(status: Int, message: String) async {
        struct Body: Encodable { var message: String }
        if status == 304 { try? await empty(.notModified); return }
        try? await json(Body(message: message), status: HTTPResponseStatus(statusCode: status))
    }

    // MARK: - streams

    /// Start a chunked body. Headers are flushed immediately so clients unblock before the first byte.
    public func beginStream(_ status: HTTPResponseStatus = .ok, contentType: String, headers: [(String, String)] = []) async throws {
        try transition(from: .idle, to: .streaming)
        try checkOpen()
        var h = baseHeaders(contentType: contentType)
        for (k, v) in headers { h.add(name: k, value: v) }
        h.add(name: "Transfer-Encoding", value: "chunked")
        try await channel.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: h))).get()
    }

    public func write(_ buffer: ByteBuffer) async throws {
        guard state == .streaming else { throw APIError(status: 500, message: "no open stream") }
        try checkOpen()
        if isHead { return }
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    }

    public func write(_ data: Data) async throws {
        try await write(ByteBuffer(bytes: data))
    }

    /// One JSON document followed by `\n` (events, stats) or `\r\n` (progress), as Docker does.
    public func writeJSON<T: Encodable>(_ value: T, terminator: String = "\n") async throws {
        var data = try JSONOut.encode(value)
        data.append(contentsOf: Array(terminator.utf8))
        try await write(data)
    }

    public func finish() async throws {
        guard state == .streaming else { return }
        lock.withLock { _state = .done }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
    }

    /// Called by the connection after the handler returns.
    func finishIfNeeded() async {
        switch state {
        case .idle: try? await empty(.ok)
        case .streaming: try? await finish()
        case .done, .hijacked: break
        }
    }

    func fail(_ error: Error) async {
        if error is CancellationError || error is ConnectionClosed { channel.close(promise: nil); return }
        let (status, message) = ErrorMap.describe(await PortConflict.annotate(error))
        switch state {
        case .idle: await sendError(status: status, message: message)
        case .streaming, .done: channel.close(promise: nil)
        case .hijacked: break
        }
    }

    // MARK: - hijack

    /// Answer `101 UPGRADED` (or a plain 200 raw stream when the client did not ask to upgrade) and
    /// turn the socket into a raw byte pipe. The HTTP codecs leave the pipeline.
    public func hijack(contentType: String = "application/vnd.docker.raw-stream", protocolName: String = "tcp") async throws -> RawConnection {
        try transition(from: .idle, to: .hijacked)
        lock.withLock { _keepAlive = false }
        try checkOpen()
        var h = HTTPHeaders([("Content-Type", contentType)])
        h.add(contentsOf: Self.dockerHeaders)
        let status: HTTPResponseStatus
        if upgradeRequested == protocolName {
            h.add(name: "Connection", value: "Upgrade")
            h.add(name: "Upgrade", value: protocolName)
            status = .custom(code: 101, reasonPhrase: "UPGRADED")
        } else {
            status = .ok
        }
        let inbox = ByteInbox(channel: channel)
        let parts = self.parts
        let onDisconnect = self.onDisconnect
        let channel = self.channel
        let peerEOF = protocolName == "h2c" ? AsyncStream<Void>.makeStream() : nil
        let head = HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: h))
        try await channel.eventLoop.submit {
            let pipeline = channel.pipeline
            let raw = RawHandler(inbox: inbox, end: peerEOF?.continuation, onInactive: onDisconnect)
            try pipeline.syncOperations.addHandler(raw, position: .after(parts.decoder))
            if let handler = parts.handler { pipeline.removeHandler(handler, promise: nil) }
            pipeline.removeHandler(parts.decoder, promise: nil)
            // Docker may half-close immediately on seeing 101. RawHandler must already own inbound EOF.
            let written = channel.writeAndFlush(head)
            pipeline.removeHandler(parts.encoder, promise: nil)
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
            return written
        }.flatMap { $0 }.get()
        return RawConnection(channel: channel, inbox: inbox, peerEOF: peerEOF?.stream)
    }
}
