import Foundation

extension FinderHTTP {
    static func children(_ resource: FinderResource, emit: (FinderNode) async throws -> Void) async throws {
        if let reader = resource.guest {
            try await reader.select("list")
            while true {
                try Task.checkCancellation()
                let record = try await reader.record()
                if record["end"]?.bool == true { return }
                guard let name = record["name"]?.string, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                      !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      let kind = record["kind"]?.string, let size = record["size"]?.int, size >= 0, let mtime = record["mtime"]?.int else {
                    throw FinderFailure(502, "invalid directory record")
                }
                // Refused objects are not advertised as files that can be opened.
                if kind == "file" || kind == "directory" { try await emit(FinderNode(name: name, kind: kind, size: size, mtime: mtime)) }
            }
        } else {
            for node in resource.children { try await emit(node) }
        }
    }

    static func byteRange(_ header: String?, size: Int64) throws -> (offset: Int64, count: Int64) {
        guard let header else { return (0, size) }
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw FinderFailure(416, "invalid range") }
        let halves = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard halves.count == 2 else { throw FinderFailure(416, "invalid range") }
        func integer(_ text: Substring) -> Int64? { !text.isEmpty && text.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } ? Int64(text) : nil }
        if halves[0].isEmpty {
            guard let suffix = integer(halves[1]), suffix > 0 else { throw FinderFailure(416, "invalid range") }
            let count = min(suffix, size)
            return (size - count, count)
        }
        guard let start = integer(halves[0]), start < size else { throw FinderFailure(416, "invalid range") }
        let last: Int64
        if halves[1].isEmpty { last = size - 1 }
        else {
            guard let requested = integer(halves[1]), requested >= start else { throw FinderFailure(416, "invalid range") }
            last = min(requested, size - 1)
        }
        return (start, last - start + 1)
    }

    static func head(_ client: FinderServerConnection, status: Int, length: Int64?, type: String, extra: String = "") async throws {
        let phrase = [200: "OK", 206: "Partial Content", 207: "Multi-Status", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large", 416: "Range Not Satisfiable",
                      431: "Request Header Fields Too Large", 502: "Bad Gateway", 503: "Service Unavailable", 507: "Insufficient Storage"][status] ?? "Error"
        let framing = length.map { "Content-Length: \($0)\r\n" } ?? "Transfer-Encoding: chunked\r\n"
        let text = "HTTP/1.1 \(status) \(phrase)\r\nConnection: close\r\nDAV: 1\r\nAllow: \(allow)\r\nCache-Control: no-cache, no-store, must-revalidate\r\nContent-Type: \(type)\r\n\(framing)\(extra)\r\n"
        try await client.write(Data(text.utf8))
    }
    static func chunk(_ client: FinderServerConnection, _ text: String) async throws {
        let body = Data(text.utf8)
        guard !body.isEmpty else { return }
        try await client.write(Data("\(String(body.count, radix: 16))\r\n".utf8))
        try await client.write(body)
        try await client.write(Data("\r\n".utf8))
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func href(_ token: String, _ parts: [String], directory: Bool) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return "/" + ([token] + parts).map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/") + (directory ? "/" : "")
    }
    static func httpDate(_ seconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
    }
}
