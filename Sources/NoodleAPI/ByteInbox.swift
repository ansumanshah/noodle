import Foundation
import NIOConcurrencyHelpers
import NIOCore

struct ConnectionClosed: Error, CustomStringConvertible {
    var description: String { "connection closed" }
}

/// Inbound bytes of one request body, or of one hijacked connection, with backpressure.
/// Above `highWater` queued bytes the socket stops reading until the consumer drains below `lowWater`.
public final class ByteInbox: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<ByteBuffer?, Error>
    private let channel: Channel
    private let lock = NIOLock()
    private var queue: [ByteBuffer] = []
    private var queued = 0
    private var finished = false
    private var failure: Error?
    private var waiter: Waiter?
    private var paused = false
    private var discarding = false
    private let highWater = 1 << 20
    private let lowWater = 256 << 10

    init(channel: Channel) { self.channel = channel }

    // MARK: producer (event loop)

    func feed(_ buffer: ByteBuffer) {
        var deliver: Waiter?
        var pause = false
        lock.withLock {
            guard !discarding, !finished, failure == nil else { return }
            if let w = waiter {
                waiter = nil
                deliver = w
            } else {
                queue.append(buffer)
                queued += buffer.readableBytes
                if queued >= highWater, !paused { paused = true; pause = true }
            }
        }
        if let d = deliver { d.resume(returning: buffer) }
        if pause { _ = channel.setOption(ChannelOptions.autoRead, value: false) }
    }

    func finish() { end(error: nil) }
    func fail(_ error: Error) { end(error: error) }

    private func end(error: Error?) {
        var w: Waiter?
        lock.withLock {
            guard !finished else { return }
            finished = true
            if let error { failure = error; queue.removeAll(); queued = 0 }
            if queue.isEmpty { w = waiter; waiter = nil }
        }
        if let w {
            if let error { w.resume(throwing: error) } else { w.resume(returning: nil) }
        }
    }

    /// Drop everything that is queued or still to come (the handler finished without reading the body).
    func discard() {
        let wasPaused: Bool = lock.withLock {
            discarding = true
            queue.removeAll(); queued = 0
            let p = paused; paused = false
            return p
        }
        if wasPaused { resumeReading() }
    }

    private func resumeReading() {
        let channel = self.channel
        channel.eventLoop.execute {
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
            channel.read()
        }
    }

    // MARK: consumer

    /// Next chunk of the body; nil at end of body (or when the peer half-closed).
    public func next() async throws -> ByteBuffer? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: Waiter) in
                enum Out { case value(ByteBuffer, Bool), end, error(Error), wait }
                let out: Out = lock.withLock {
                    if !queue.isEmpty {
                        let b = queue.removeFirst()
                        queued -= b.readableBytes
                        var resume = false
                        if paused, queued <= lowWater { paused = false; resume = true }
                        return .value(b, resume)
                    }
                    if let f = failure { return .error(f) }
                    if finished { return .end }
                    if Task.isCancelled { return .error(CancellationError()) }
                    waiter = c
                    return .wait
                }
                switch out {
                case .value(let b, let resume): if resume { resumeReading() }; c.resume(returning: b)
                case .end: c.resume(returning: nil)
                case .error(let e): c.resume(throwing: e)
                case .wait: break
                }
            }
        } onCancel: {
            let w: Waiter? = lock.withLock { let w = waiter; waiter = nil; return w }
            w?.resume(throwing: CancellationError())
        }
    }

    /// Read the whole body into memory, failing above `limit` bytes.
    public func readAll(limit: Int = 32 << 20) async throws -> Data {
        var out = Data()
        while let b = try await next() {
            out.append(contentsOf: b.readableBytesView)
            if out.count > limit { throw APIError(status: 413, message: "request body too large") }
        }
        return out
    }
}
