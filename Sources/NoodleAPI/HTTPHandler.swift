import Foundation
import NIOCore
import NIOHTTP1

/// Per-connection HTTP/1.1 state machine. Runs on the event loop and never blocks: each request is
/// dispatched to a Swift Task, and body bytes flow through a `ByteInbox` with backpressure.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    final class Active: @unchecked Sendable {
        let inbox: ByteInbox
        let writer: ResponseWriter
        var requestEnded = false
        var handlerDone = false
        let id = UUID()
        var task: Task<Void, Never>?
        init(inbox: ByteInbox, writer: ResponseWriter) { self.inbox = inbox; self.writer = writer }
    }

    private let router: Router
    private let parts: PipelineParts
    private let connections: HTTPConnections
    private var context: ChannelHandlerContext?
    private var current: Active?
    private var pending: [HTTPServerRequestPart] = []
    private var closing = false
    private static let maxPending = 64

    private let relayed: Bool

    init(router: Router, parts: PipelineParts, connections: HTTPConnections, relayed: Bool = false) {
        self.router = router; self.parts = parts; self.connections = connections; self.relayed = relayed
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    // The context owns this handler: keeping it after removal leaks the handler, its parser and the pipeline per connection.
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { handle(unwrapInboundIn(data)) }

    private func handle(_ part: HTTPServerRequestPart) {
        if !pending.isEmpty || (current?.requestEnded ?? false) {
            // Pipelined requests wait in memory; a client that keeps sending past this is dropped.
            guard pending.count < Self.maxPending else { context?.close(promise: nil); return }
            pending.append(part); return
        }
        switch part {
        case .head(let head):
            guard current == nil else { pending.append(part); return }
            begin(head)
        case .body(let b): current?.inbox.feed(b)
        case .end:
            current?.requestEnded = true
            current?.inbox.finish()
            checkDone()
        }
    }

    private func begin(_ head: HTTPRequestHead) {
        guard let channel = context?.channel else { return }
        let (rawPath, rawQuery) = URLParts.split(uri: head.uri)
        var segments = URLParts.segments(rawPath)
        var version = APIInfo.apiVersion
        if let f = segments.first, URLParts.isVersionSegment(f) { version = String(f.dropFirst()); segments.removeFirst() }
        let upgrade = head.headers.first(name: "Upgrade")?.lowercased()
        let inbox = ByteInbox(channel: channel)
        let writer = ResponseWriter(channel: channel, parts: parts, keepAlive: head.isKeepAlive && !closing, isHead: head.method == .HEAD,
                                    upgradeRequested: upgrade)
        let request = Request(method: head.method, segments: segments, query: URLParts.parseQuery(rawQuery),
                              headers: head.headers, apiVersion: version, body: inbox)
        let active = Active(inbox: inbox, writer: writer)
        current = active
        writer.onDisconnect = { [weak active] in active?.task?.cancel() }
        let router = self.router, relayed = self.relayed
        let task = Task {
            if !Task.isCancelled { await router.serve(request, writer, relayed: relayed) }
            channel.eventLoop.execute { self.handlerFinished(active) }
        }
        active.task = task
        connections.addTask(task, id: active.id)
    }

    private func handlerFinished(_ active: Active) {
        connections.removeTask(active.id)
        guard current === active else { return }
        active.handlerDone = true
        if active.writer.state == .hijacked { current = nil; return }
        if !active.requestEnded { active.inbox.discard() }
        checkDone()
    }

    private func checkDone() {
        guard let a = current, a.handlerDone, a.requestEnded else { return }
        current = nil
        if !a.writer.keepAlive || closing { context?.close(promise: nil); return }
        let queued = pending
        pending = []
        for p in queued { handle(p) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        current?.task?.cancel()
        current?.inbox.fail(ConnectionClosed())
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let e = event as? ChannelEvent, e == .inputClosed else { context.fireUserInboundEventTriggered(event); return }
        // The client closed its side: like Docker's daemon, treat it as a cancelled request.
        closing = true
        current?.task?.cancel()
        current?.inbox.fail(ConnectionClosed())
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        current?.task?.cancel()
        context.close(promise: nil)
    }
}
