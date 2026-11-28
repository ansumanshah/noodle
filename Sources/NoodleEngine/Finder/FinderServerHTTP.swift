import Foundation

enum FinderHTTP {
    static let allow = "OPTIONS, HEAD, GET, PROPFIND"
    struct Request {
        var method: String
        var parts: [String]
        var headers: [String: String]
        var body: Data
    }

    static func serve(_ client: FinderServerConnection, engine: Engine, token: String, port: Int) async {
        var started = false
        do {
            let request = try await request(client, token: token, port: port)
            if request.method == "OPTIONS" {
                try await head(client, status: 200, length: 0, type: "text/plain")
                return
            }
            if request.method == "PROPFIND", !["0", "1"].contains(request.headers["depth"] ?? "infinity") {
                let body = Data("<?xml version=\"1.0\"?><D:error xmlns:D=\"DAV:\"><D:propfind-finite-depth/></D:error>".utf8)
                try await head(client, status: 403, length: Int64(body.count), type: "application/xml; charset=utf-8")
                try await client.write(body)
                return
            }
            let properties = request.method == "PROPFIND" ? try FinderProperties.parse(request.body) : FinderProperties()
            let resource = try await engine.finderResource(request.parts)
            defer { resource.guest?.close() }
            try await withTaskCancellationHandler {
                if request.method == "PROPFIND" {
                    try await head(client, status: 207, length: nil, type: "application/xml; charset=utf-8")
                    started = true
                    try await chunk(client, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">")
                    let path = href(token, request.parts, directory: resource.node.isDirectory)
                    try await chunk(client, properties.response(resource.node, path: path))
                    if resource.node.isDirectory, request.headers["depth"] == "1" {
                        try await children(resource) { node in
                            try await chunk(client, properties.response(node, path: href(token, request.parts + [node.name], directory: node.isDirectory)))
                        }
                    } else { try await resource.guest?.select("stat") }
                    try await chunk(client, "</D:multistatus>")
                    try await client.write(Data("0\r\n\r\n".utf8))
                } else if resource.node.isDirectory {
                    if request.method == "HEAD" {
                        try await resource.guest?.select("stat")
                        try await head(client, status: 200, length: nil, type: "text/html; charset=utf-8")
                        return
                    }
                    try await head(client, status: 200, length: nil, type: "text/html; charset=utf-8")
                    started = true
                    try await chunk(client, "<!doctype html><meta charset=\"utf-8\"><title>Noodle files</title><ul>")
                    try await children(resource) { node in
                        let path = href(token, request.parts + [node.name], directory: node.isDirectory)
                        try await chunk(client, "<li><a href=\"\(escape(path))\">\(escape(node.name))</a></li>")
                    }
                    try await chunk(client, "</ul>")
                    try await client.write(Data("0\r\n\r\n".utf8))
                } else {
                    let size = resource.node.size
                    let range = request.method == "GET" ? request.headers["range"] : nil
                    let selected: (offset: Int64, count: Int64)
                    do { selected = try byteRange(range, size: size) }
                    catch {
                        try await resource.guest?.select("stat")
                        try await head(client, status: 416, length: 0, type: "text/plain", extra: "Content-Range: bytes */\(size)\r\n")
                        return
                    }
                    var extra = "Accept-Ranges: bytes\r\nLast-Modified: \(httpDate(resource.node.mtime))\r\n"
                    if range != nil { extra += "Content-Range: bytes \(selected.offset)-\(selected.offset + selected.count - 1)/\(size)\r\n" }
                    guard let reader = resource.guest else { throw FinderFailure(502, "missing file stream") }
                    if request.method == "HEAD" { try await reader.select("stat") }
                    else { try await reader.select("read", offset: selected.offset, count: selected.count) }
                    try await head(client, status: range == nil ? 200 : 206, length: selected.count, type: "application/octet-stream", extra: extra)
                    started = true
                    if request.method != "HEAD" {
                        var remaining = selected.count
                        while remaining > 0 {
                            try Task.checkCancellation()
                            guard let bytes = try await reader.bytes(), !bytes.isEmpty, Int64(bytes.count) <= remaining else {
                                throw FinderFailure(502, "incomplete guest file read")
                            }
                            try await client.write(bytes)
                            remaining -= Int64(bytes.count)
                        }
                    }
                }
            } onCancel: { resource.guest?.close() }
        } catch {
            if !started, !Task.isCancelled {
                let failure: FinderFailure
                switch error {
                case let value as FinderFailure: failure = value
                case let value as GuestError:
                    switch value.errno {
                    case ENOENT, ENOTDIR: failure = FinderFailure(404, "file not found")
                    // Guest errnos are Linux numbers; ELOOP is 40 there but 62 on Darwin.
                    case EACCES, EPERM, 40, EXDEV: failure = FinderFailure(403, "path refused")
                    default: failure = FinderFailure(503, "guest read unavailable")
                    }
                default: failure = FinderFailure(503, "file service unavailable")
                }
                let body = Data((failure.message + "\n").utf8)
                try? await head(client, status: failure.status, length: Int64(body.count), type: "text/plain; charset=utf-8")
                try? await client.write(body)
            }
        }
    }

}
