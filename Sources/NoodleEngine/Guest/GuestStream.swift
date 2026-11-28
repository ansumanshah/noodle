import Foundation
import NoodleCore

/// One connection on the vsock stream port after the handshake. Either multiplexed frames (attach/exec/logs)
/// or raw bytes (archives, layers, relay). Always call `close()` when done.
public final class GuestStream: @unchecked Sendable {
    let channel: FDChannel
    private var carry: Data
    private var frameDecoder = StreamFrameDecoder()
    private var jsonDecoder = ControlFrameDecoder()
    private let onClose: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var didClose = false
    /// Sees every frame returned by `nextFrame()`, e.g. to record an exec exit code.
    public var frameObserver: (@Sendable (StreamFrame) -> Void)?

    init(channel: FDChannel, leftover: Data, onClose: (@Sendable () -> Void)? = nil) {
        self.channel = channel; self.carry = leftover; self.onClose = onClose
    }

    // MARK: raw reads

    /// Next chunk of body bytes; nil at EOF.
    public func readChunk() async throws -> Data? {
        if !carry.isEmpty { let d = carry; carry = Data(); return d }
        return try await channel.read()
    }

    // MARK: framed reads

    /// Next multiplexed frame; nil at EOF.
    public func nextFrame() async throws -> StreamFrame? {
        if !carry.isEmpty { frameDecoder.append(carry); carry = Data() }
        while true {
            if let f = try frameDecoder.next() { frameObserver?(f); return f }
            guard let d = try await channel.read() else { return nil }
            frameDecoder.append(d)
        }
    }

    /// One length-prefixed JSON frame (the result after `unpack_layer`, `archive_put`, ...).
    public func readResult() async throws -> [String: JSONValue] {
        if !carry.isEmpty { jsonDecoder.append(carry); carry = Data() }
        while true {
            if let payload = try jsonDecoder.next() {
                let v = try JSONDecoder().decode(JSONValue.self, from: payload)
                let o = v.object ?? [:]
                if o["ok"]?.bool == false { throw GuestError(o["error"]?.string ?? "guest error", errno: Int32(truncatingIfNeeded: o["errno"]?.int ?? 0)) }
                return o
            }
            guard let d = try await channel.read() else { throw GuestError("stream closed before result") }
            jsonDecoder.append(d)
        }
    }

    // MARK: writes

    public func write(_ data: Data) async throws { try await channel.write(data) }
    public func write(frame: StreamFrame) async throws { try await channel.write(frame.encoded()) }
    public func writeStdin(_ data: Data) async throws { try await write(frame: .stdin(data)) }
    public func closeStdin() async throws { try await write(frame: .stdinEOF) }
    public func resize(rows: UInt16, cols: UInt16) async throws { try await write(frame: .resize(rows: rows, cols: cols)) }
    /// Half-close the write side (raw streams: tells the guest the body is complete).
    public func finishWriting() { channel.shutdownWrite() }

    /// Copy a file to the guest as a raw body.
    public func send(file url: URL) async throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        // One buffer for the whole file. `write` returns only after the bytes are sent, so reuse is safe.
        let size = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(h.fileDescriptor, buf, size)
            if n < 0, errno == EINTR { continue }
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            try await channel.write(Data(bytesNoCopy: buf, count: n, deallocator: .none))
        }
    }

    public func close() {
        lock.lock(); let already = didClose; didClose = true; lock.unlock()
        if already { return }
        channel.close()
        onClose?()
    }

    deinit { close() }
}
