import Darwin
import Foundation
import Network
import Security

extension TLSSession {
    // MARK: - Bounded ClientHello SNI inspection

    /// Assemble a ClientHello across TLS records while retaining the exact encrypted wire bytes. Network.framework
    /// validates the actual handshake. This inspection only selects the existing per-host identity and allowlist.
    func clientHello(deadline: DispatchTime) -> (host: String, wire: Data)? {
        var wire = Data(), handshake = [UInt8](), recordOffset = 0
        while wire.count < 128 * 1024 {
            while wire.count - recordOffset >= 5 {
                guard wire[recordOffset] == 22, wire[recordOffset + 1] == 3 else { return nil }
                let count = Int(wire[recordOffset + 3]) << 8 | Int(wire[recordOffset + 4])
                guard count > 0, count <= 16 * 1024 else { return nil }
                guard wire.count - recordOffset >= 5 + count else { break }
                handshake.append(contentsOf: wire[(recordOffset + 5)..<(recordOffset + 5 + count)])
                recordOffset += 5 + count
                guard handshake.count <= 64 * 1024 else { return nil }
                if handshake.count >= 4 {
                    guard handshake[0] == 1 else { return nil }
                    let size = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
                    guard size <= 64 * 1024 - 4 else { return nil }
                    if handshake.count >= size + 4 {
                        guard let host = Self.serverName(Array(handshake[4..<(4 + size)])) else { return nil }
                        return (host, wire)
                    }
                }
            }
            var bytes = [UInt8](repeating: 0, count: min(16 * 1024, 128 * 1024 - wire.count))
            let count = Darwin.read(tls, &bytes, bytes.count)
            if count > 0 { wire.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { return nil }
            else if errno == EINTR { continue }
            else if errno != EAGAIN || !wait(tls, events: Int16(POLLIN), deadline: deadline) { return nil }
        }
        return nil
    }

    private static func serverName(_ bytes: [UInt8]) -> String? {
        var index = 34 // legacy_version and random
        func take(_ count: Int) -> Bool {
            guard count >= 0, index <= bytes.count - count else { return false }
            index += count; return true
        }
        func length(_ width: Int) -> Int? {
            guard take(width) else { return nil }
            return bytes[(index - width)..<index].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard let session = length(1), session <= 32, take(session), let ciphers = length(2),
              ciphers >= 2, ciphers.isMultiple(of: 2), take(ciphers), let compression = length(1),
              compression > 0, take(compression), let extensions = length(2), extensions == bytes.count - index else { return nil }
        var host: String?, sawSNI = false
        while index < bytes.count {
            guard let kind = length(2), let size = length(2), size <= bytes.count - index else { return nil }
            let end = index + size
            if kind == 0 {
                guard !sawSNI, let listSize = length(2), listSize == end - index else { return nil }
                sawSNI = true
                while index < end {
                    guard let type = length(1), let nameSize = length(2), nameSize > 0, nameSize <= end - index else { return nil }
                    if type == 0 {
                        guard host == nil, nameSize < 256 else { return nil }
                        let name = bytes[index..<(index + nameSize)]
                        guard name.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                              let value = String(bytes: name, encoding: .ascii) else { return nil }
                        host = value.lowercased()
                    }
                    index += nameSize
                }
            } else { index = end }
            guard index == end else { return nil }
        }
        return host
    }

    func wait(_ fd: Int32, events: Int16, deadline: DispatchTime) -> Bool {
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { return false }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining / 1_000_000 + 1, UInt64(Int32.max))))
            if result > 0 { return item.revents & events != 0 }
            if result == 0 || errno != EINTR { return false }
        }
    }
}
