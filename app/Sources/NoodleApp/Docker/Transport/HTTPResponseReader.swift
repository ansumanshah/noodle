import Foundation
import Network

struct HTTPHead: Sendable {
    var status: Int
    var headers: [String: String]
}

/// Reads one response off a connection: head first, then body pieces already de-framed.
final class HTTPResponseReader: @unchecked Sendable {
    private enum Framing { case chunked, length(Int), untilClose }
    private let conn: UnixConnection
    private var buffer = Data()
    private var framing: Framing = .untilClose
    private var finished = false
    private(set) var head = HTTPHead(status: 0, headers: [:])

    init(conn: UnixConnection) { self.conn = conn }

    func readHead() async throws {
        let sep = Data([13, 10, 13, 10])
        while buffer.range(of: sep) == nil {
            guard let d = try await conn.receive() else { throw TransportError.closed }
            buffer.append(d)
            if buffer.count > 256 * 1024 { throw TransportError.malformed("head too large") }
        }
        let r = buffer.range(of: sep)!
        let text = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<r.upperBound)
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).makeIterator()
        guard let first = lines.next() else { throw TransportError.malformed("empty") }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw TransportError.malformed(String(first)) }
        var headers: [String: String] = [:]
        while let line = lines.next() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        head = HTTPHead(status: status, headers: headers)
        if status == 101 {
            framing = .untilClose
        } else if status == 204 || status == 304 {
            framing = .length(0)
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunked
        } else if let n = headers["content-length"].flatMap({ Int($0) }) {
            framing = .length(n)
        } else {
            framing = .untilClose
        }
    }

    /// Next de-framed body piece, or nil at the end.
    func nextBody() async throws -> Data? {
        if finished { return nil }
        switch framing {
        case .length(let remaining):
            if remaining == 0 { finished = true; return nil }
            if buffer.isEmpty {
                guard let d = try await conn.receive() else { finished = true; throw TransportError.closed }
                buffer.append(d)
            }
            let take = min(remaining, buffer.count)
            let out = buffer.prefix(take)
            buffer.removeFirst(take)
            framing = .length(remaining - take)
            return Data(out)
        case .untilClose:
            if !buffer.isEmpty { defer { buffer.removeAll() }; return buffer }
            guard let d = try await conn.receive() else { finished = true; return nil }
            return d
        case .chunked:
            let crlf = Data([13, 10])
            while true {
                if let r = buffer.range(of: crlf) {
                    let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                    let hex = line.split(separator: ";").first.map(String.init) ?? ""
                    guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                        throw TransportError.malformed("chunk size \(line)")
                    }
                    if size == 0 { finished = true; return nil }
                    let need = r.upperBound - buffer.startIndex + size + 2
                    while buffer.count < need {
                        guard let d = try await conn.receive() else { finished = true; throw TransportError.closed }
                        buffer.append(d)
                    }
                    let start = buffer.startIndex + (r.upperBound - buffer.startIndex)
                    let out = Data(buffer[start..<start + size])
                    buffer.removeFirst(need)
                    return out
                }
                guard let d = try await conn.receive() else { finished = true; return nil }
                buffer.append(d)
            }
        }
    }

    /// Holds at most `limit` bytes and drains the rest (bounded by the caller's deadline).
    func readAll(limit: Int = .max) async throws -> Data {
        var out = Data()
        // Keep at most `limit` bytes but drain to the end: closing early kills a still-running exec.
        while let p = try await nextBody() { if out.count < limit { out.append(p.prefix(limit - out.count)) } }
        return out
    }
}
