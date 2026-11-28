import Foundation
import NIOCore

/// A connection taken over from HTTP (attach, exec start): raw bytes both ways with half-close.
public final class RawConnection: @unchecked Sendable {
    let channel: Channel
    public let inbox: ByteInbox
    let peerEOF: AsyncStream<Void>?

    init(channel: Channel, inbox: ByteInbox, peerEOF: AsyncStream<Void>?) {
        self.channel = channel; self.inbox = inbox; self.peerEOF = peerEOF
    }

    public func write(_ buffer: ByteBuffer) async throws {
        guard channel.isActive else { throw ConnectionClosed() }
        try await channel.writeAndFlush(buffer).get()
    }

    public func write(_ data: Data) async throws {
        try await write(ByteBuffer(bytes: data))
    }

    /// Docker multiplexed frame: `[stream, 0, 0, 0, size u32 BE] + payload`.
    public func writeMux(stream: UInt8, _ payload: Data) async throws {
        var b = channel.allocator.buffer(capacity: payload.count + 8)
        b.writeInteger(stream)
        b.writeBytes([0, 0, 0])
        b.writeInteger(UInt32(payload.count))
        b.writeBytes(payload)
        try await write(b)
    }

    /// Half-close: the client sees EOF but may still have data in flight to us.
    public func closeOutput() { channel.close(mode: .output, promise: nil) }
    public func close() { channel.close(promise: nil) }
}

final class RawHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let inbox: ByteInbox
    let end: AsyncStream<Void>.Continuation?
    let onInactive: (@Sendable () -> Void)?
    init(inbox: ByteInbox, end: AsyncStream<Void>.Continuation?, onInactive: (@Sendable () -> Void)? = nil) {
        self.inbox = inbox; self.end = end; self.onInactive = onInactive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { inbox.feed(unwrapInboundIn(data)) }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, e == .inputClosed { inbox.finish(); end?.finish() } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.finish(); end?.finish()
        onInactive?()   // wakes a handler blocked on the guest stream: the client is gone
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { inbox.fail(error); end?.finish(); context.close(promise: nil) }
}
