import Foundation
import Network

struct DockerSocket: Sendable {
    let path: String

    private func build(_ method: String, _ target: String, body: Data?, contentType: String?, upgrade: Bool) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: noodle\r\nUser-Agent: NoodleApp\r\nConnection: close\r\nAccept: */*\r\n"
        if upgrade { head = head.replacingOccurrences(of: "Connection: close", with: "Connection: Upgrade\r\nUpgrade: tcp") }
        if let body {
            head += "Content-Type: \(contentType ?? "application/json")\r\nContent-Length: \(body.count)\r\n"
        } else if method != "GET" && method != "HEAD" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    private func open(_ method: String, _ target: String, body: Data?, contentType: String?, upgrade: Bool = false) async throws -> (UnixConnection, HTTPResponseReader) {
        let conn = UnixConnection(path: path)
        do {
            try await withTaskCancellationHandler {
                try await conn.start()
                try await conn.send(build(method, target, body: body, contentType: contentType, upgrade: upgrade))
            } onCancel: { conn.close() }
            let reader = HTTPResponseReader(conn: conn)
            try await withTaskCancellationHandler { try await reader.readHead() } onCancel: { conn.close() }
            return (conn, reader)
        } catch {
            conn.close()
            throw error
        }
    }

    /// Whole-body request with a deadline. `maxBody` caps retained bytes; the body is still drained so the peer finishes.
    func request(_ method: String, _ target: String, body: Data? = nil, contentType: String? = nil,
                 timeout: Double = 20, upgrade: Bool = false, maxBody: Int = .max) async throws -> (status: Int, body: Data) {
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            group.addTask {
                let (conn, reader) = try await self.open(method, target, body: body, contentType: contentType, upgrade: upgrade)
                defer { conn.close() }
                let data = try await withTaskCancellationHandler { try await reader.readAll(limit: maxBody) } onCancel: { conn.close() }
                return (reader.head.status, data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TransportError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Streaming request. Throws `HTTPFailure` for status >= 300. Cancel the consuming task to close.
    func stream(_ method: String, _ target: String, body: Data? = nil, contentType: String? = nil) async throws -> AsyncThrowingStream<Data, Error> {
        let (conn, reader) = try await open(method, target, body: body, contentType: contentType)
        if reader.head.status >= 300 {
            let data = (try? await reader.readAll()) ?? Data()
            conn.close()
            throw HTTPFailure(status: reader.head.status, message: Self.errorMessage(data))
        }
        // Pull-based: the next read happens only when the consumer asks, so a slow consumer applies backpressure.
        let closer = Closer(conn)
        return AsyncThrowingStream(unfolding: {
            do {
                let piece = try await withTaskCancellationHandler { try await reader.nextBody() } onCancel: { closer.conn.close() }
                if piece == nil { closer.conn.close() }
                return piece
            } catch {
                closer.conn.close()
                if Task.isCancelled || error is CancellationError { return nil }
                throw error
            }
        })
    }

    /// Closes the connection when the stream is dropped without being read to the end.
    private final class Closer: @unchecked Sendable {
        let conn: UnixConnection
        init(_ conn: UnixConnection) { self.conn = conn }
        deinit { conn.close() }
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let m = obj["message"] as? String { return m }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
