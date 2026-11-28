import Foundation
import CryptoKit

public enum Digest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String { "sha256:" + sha256Hex(data) }

    /// First 12 hex characters of a `sha256:` digest, as Docker prints image and layer IDs.
    public static func short(_ digest: String) -> String { String(digest.dropFirst(7).prefix(12)) }

    /// Split `sha256:abc` into (`sha256`, `abc`). A bare hex string is treated as sha256.
    public static func split(_ digest: String) -> (String, String) {
        if let i = digest.firstIndex(of: ":") {
            return (String(digest[..<i]), String(digest[digest.index(after: i)...]))
        }
        return ("sha256", digest)
    }

    public static func isValid(_ digest: String) -> Bool {
        let (algo, hex) = split(digest)
        guard algo == "sha256", hex.count == 64 else { return false }
        return hex.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Incremental hasher.
    public struct Hasher {
        private var inner = SHA256()
        public init() {}
        public mutating func update(_ data: Data) { inner.update(data: data) }
        public mutating func update(_ buffer: UnsafeRawBufferPointer) { inner.update(bufferPointer: buffer) }
        public mutating func finalize() -> String {
            "sha256:" + inner.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Hash a file with one reused buffer, so a large blob never leaves a pile of autoreleased chunks behind.
    public static func sha256(file url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let size = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var hasher = Hasher()
        while true {
            let n = read(fd, buf, size)
            if n < 0, errno == EINTR { continue }
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buf, count: n))
        }
        return hasher.finalize()
    }
}

public enum IDs {
    /// 64 hex chars, like Docker container/network ids.
    public static func random64() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
