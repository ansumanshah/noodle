import Foundation

extension FinderHTTP {
    static func request(_ client: FinderServerConnection, token: String, port: Int) async throws -> Request {
        let boundary = Data("\r\n\r\n".utf8)
        var data = Data()
        while data.range(of: boundary) == nil {
            guard let bytes = try await client.read() else { throw FinderFailure(400, "incomplete request") }
            data.append(bytes)
            guard data.count <= 80 << 10 else { throw FinderFailure(431, "request headers too large") }
        }
        guard let end = data.range(of: boundary), end.lowerBound <= 16 << 10 else { throw FinderFailure(431, "request headers too large") }
        guard let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw FinderFailure(400, "invalid headers") }
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])) else { throw FinderFailure(400, "invalid request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw FinderFailure(400, "invalid header") }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw FinderFailure(400, "duplicate or empty header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)" else { throw FinderFailure(403, "host refused") }
        let rawPath = String(first[1])
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//"), !rawPath.contains("?"), !rawPath.contains("#"), rawPath.utf8.count <= 8192 else {
            throw FinderFailure(403, "path refused")
        }
        var parts: [String] = []
        for segment in rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty {
                guard rawPath.hasSuffix("/"), parts.count == rawPath.split(separator: "/").count else { throw FinderFailure(403, "path refused") }
                continue
            }
            guard let decoded = String(segment).removingPercentEncoding, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw FinderFailure(403, "path refused")
            }
            parts.append(decoded)
        }
        guard parts.first == token else { throw FinderFailure(403, "capability refused") }
        let method = String(first[0])
        guard ["OPTIONS", "HEAD", "GET", "PROPFIND"].contains(method) else { throw FinderFailure(405, "Finder view is read-only") }
        guard headers["transfer-encoding"] == nil else { throw FinderFailure(400, "chunked requests are not supported") }
        let length = headers["content-length"].flatMap(Int.init) ?? (headers["content-length"] == nil ? 0 : -1)
        guard length >= 0, length <= 64 << 10 else { throw FinderFailure(413, "request body too large") }
        var body = Data(data[end.upperBound...])
        if method == "PROPFIND" {
            if headers["expect"]?.lowercased() == "100-continue", body.count < length { try await client.write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
            while body.count < length {
                guard let bytes = try await client.read() else { throw FinderFailure(400, "incomplete request body") }
                body.append(bytes)
                guard body.count <= 128 << 10 else { throw FinderFailure(413, "request body too large") }
            }
            body = Data(body.prefix(length))
        } else { body = Data() }
        return Request(method: method, parts: Array(parts.dropFirst()), headers: headers, body: body)
    }
}
