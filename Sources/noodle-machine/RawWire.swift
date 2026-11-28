import Foundation
import CryptoKit

/// The guest agent's listeners (NoodleWire in NoodleCore, which this helper does not link).
let rawControlPort: UInt32 = 1032
let rawStreamPort: UInt32 = 1033

final class RawConnectionResult: @unchecked Sendable {
    let lock = NSLock(), ready = DispatchSemaphore(value: 0)
    private var expired = false
    private var descriptor: Int32?
    func complete(_ fd: Int32?) { lock.lock(); defer { lock.unlock() }; if expired { if let fd { close(fd) } } else { descriptor = fd; ready.signal() } }
    func wait(_ timeout: Double) -> Int32? {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }; expired = true; return descriptor
    }
}

final class RawWire {
    let fd: Int32
    var id = 0
    init(_ fd: Int32, timeout seconds: Int) {
        self.fd = fd
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { close(fd) }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw rawError("guest write failed: \(String(cString: strerror(errno)))") }; offset += n
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress! + offset, count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw rawError("guest stream closed or timed out") }; offset += n
            }
        }; return data
    }
    func send(_ value: RawJSON) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        var count = UInt32(data.count).bigEndian
        try write(withUnsafeBytes(of: &count) { Data($0) }); try write(data)
    }
    func response() throws -> RawJSON {
        let count = try read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count <= 16 * 1024 * 1024, let json = try JSONSerialization.jsonObject(with: read(Int(count))) as? RawJSON else { throw rawError("invalid guest frame") }
        if json["ok"] as? Bool == false { throw rawError(json["error"] as? String ?? "guest request failed") }; return json
    }
    func request(_ value: RawJSON) throws -> RawJSON {
        id += 1; var value = value; value["id"] = id; try send(value)
        while true { let json = try response(); if json["id"] as? Int == id { return json } }
    }
}
