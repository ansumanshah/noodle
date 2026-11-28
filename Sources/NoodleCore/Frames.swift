import Foundation

/// Noodle's host and guest vsock contract (docs/architecture/protocol.md).
///
/// All four ports sit in one block, 1030 to 1033. The host listens on the lower
/// two, the guest agent on the upper two, so a port number alone says which
/// side dials.
public enum NoodleWire {
    /// Host listens. The agent dials it once per SSH agent client inside a container.
    public static let sshAgentPort: UInt32 = 1030
    /// Host listens (after the first container that binds the Docker socket). The agent dials it once per client of its Docker API socket.
    public static let dockerApiPort: UInt32 = 1035
    /// Host listens. The agent dials it and hangs up as soon as both of its listeners are bound.
    public static let readyPort: UInt32 = 1031
    /// Guest listens. The host keeps one connection open for request and response frames.
    public static let controlPort: UInt32 = 1032
    /// Guest listens. One connection per stream op: attach, exec, logs, layer and file transfers.
    public static let streamPort: UInt32 = 1033
    /// Hard cap on one control frame's payload (16 MiB, the guest agent's `max_frame`). Bulk data uses the stream port.
    public static let maxControlFrame: Int = 16 * 1024 * 1024
}

public enum FrameError: Error, Equatable {
    case tooLarge(Int)
    case malformed(String)
}

/// `u32 length` (big-endian) + payload.
public enum LengthPrefixed {
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Incremental decoder for `u32 length` + JSON frames.
public struct ControlFrameDecoder: Sendable {
    private var buffer = Data()
    private var offset = 0
    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Next complete frame payload, or nil when more bytes are needed.
    public mutating func next() throws -> Data? {
        let avail = buffer.count - offset
        guard avail >= 4 else { return nil }
        let base = buffer.startIndex + offset
        let len = Int(UInt32(buffer[base]) << 24 | UInt32(buffer[base + 1]) << 16 | UInt32(buffer[base + 2]) << 8 | UInt32(buffer[base + 3]))
        guard len <= NoodleWire.maxControlFrame else { throw FrameError.tooLarge(len) }
        guard avail >= 4 + len else { return nil }
        let payload = buffer.subdata(in: (base + 4)..<(base + 4 + len))
        offset += 4 + len
        if offset > 65536 && offset * 2 > buffer.count {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        return payload
    }

    /// Bytes received past the last decoded frame (used when a connection switches to a raw body).
    public mutating func takeRemainder() -> Data {
        let rest = buffer.subdata(in: (buffer.startIndex + offset)..<buffer.endIndex)
        buffer.removeAll(); offset = 0
        return rest
    }
}

/// Multiplexed stream body frame: `u8 kind`, `u32 length`, bytes.
public struct StreamFrame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case stdin = 0, stdout = 1, stderr = 2, exit = 3, stdinEOF = 4, resize = 5
    }
    public var kind: Kind
    public var payload: Data
    public init(kind: Kind, payload: Data = Data()) { self.kind = kind; self.payload = payload }

    public static func stdin(_ d: Data) -> StreamFrame { .init(kind: .stdin, payload: d) }
    public static var stdinEOF: StreamFrame { .init(kind: .stdinEOF) }
    public static func resize(rows: UInt16, cols: UInt16) -> StreamFrame {
        var d = Data()
        d.append(UInt8(rows >> 8)); d.append(UInt8(rows & 0xff))
        d.append(UInt8(cols >> 8)); d.append(UInt8(cols & 0xff))
        return .init(kind: .resize, payload: d)
    }

    public func encoded() -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(kind.rawValue)
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Exit code for an `.exit` frame (`i32` big-endian).
    public var exitCode: Int32? {
        guard kind == .exit, payload.count >= 4 else { return nil }
        let b = [UInt8](payload.prefix(4))
        return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }
}

public struct StreamFrameDecoder: Sendable {
    private var buffer = Data()
    private var offset = 0
    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    public mutating func next() throws -> StreamFrame? {
        let avail = buffer.count - offset
        guard avail >= 5 else { return nil }
        let base = buffer.startIndex + offset
        guard let kind = StreamFrame.Kind(rawValue: buffer[base]) else {
            throw FrameError.malformed("unknown stream kind \(buffer[base])")
        }
        let len = Int(UInt32(buffer[base + 1]) << 24 | UInt32(buffer[base + 2]) << 16 | UInt32(buffer[base + 3]) << 8 | UInt32(buffer[base + 4]))
        guard len <= NoodleWire.maxControlFrame else { throw FrameError.tooLarge(len) }
        guard avail >= 5 + len else { return nil }
        let payload = buffer.subdata(in: (base + 5)..<(base + 5 + len))
        offset += 5 + len
        if offset > 65536 && offset * 2 > buffer.count {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        return StreamFrame(kind: kind, payload: payload)
    }
}
