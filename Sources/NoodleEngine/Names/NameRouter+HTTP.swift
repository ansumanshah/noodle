import Foundation
import NoodleCore

extension NameRouter {
    func serve(_ client: FDChannel) async {
        var head = Data()
        let end = Data("\r\n\r\n".utf8)
        // One deadline for the whole header, so trickling a byte at a time cannot extend it.
        let deadline = ContinuousClock.now + Self.headerTimeout
        do {
            while head.range(of: end) == nil {
                guard let d = try await readWithTimeout(client, until: deadline) else { client.close(); return }
                head.append(d)
                if head.count > 64 * 1024 { await reply(client, 431, "Request Header Fields Too Large", ""); return }
            }
        } catch { client.close(); return }
        let request = RequestHead(String(decoding: head, as: UTF8.self))
        let host = request.host
        let html = Self.prefersHTML(request.accept)
        if request.hop {
            await fail(client, 508, "Loop Detected", html: html, name: host, error: "Loop detected: this request already went through Noodle.",
                       hint: "A name points at the router's own port. Point it at the app's port instead.")
            return
        }
        guard let (target, open) = lookup(host) else {
            let known = names().map { "<li><code>\(Self.escape($0))</code></li>" }.joined()
            let listing = known.isEmpty ? "<p>Start a container with an HTTP port to register a name.</p>" : "<p>Available addresses:</p><ul>\(known)</ul>"
            await fail(client, 404, "Not Found", html: html, name: host, error: "No destination for this name.",
                       hint: "Run `noodle names` to list names, or `noodle names add NAME PORT` for a process on this Mac.",
                       page: "<h1>Address unavailable</h1><p><code>\(Self.escape(host))</code> has no destination in Noodle's routing table.</p>\(listing)")
            return
        }
        let forwarded = Self.markHop(head)
        do {
            if let open {
                let stream = try await open("relay_tcp", target.ip, target.port)
                try await stream.write(forwarded)
                await PortListener.bridge(client, stream)
            } else {
                let upstream = try await Self.connectHost(port: target.port)
                defer { upstream.close() }
                try await upstream.write(forwarded)
                await Self.bridgeHost(client, upstream)
            }
        } catch {
            await fail(client, html ? 503 : 502, html ? "Service Unavailable" : "Bad Gateway", html: html, name: host,
                       error: "Nothing answered on port \(target.port).", hint: "Start the app on port \(target.port), then retry.",
                       page: "Noodle could not reach \(Self.escape(host)) on port \(target.port) yet.", retryAfter: 5)
        }
    }

    private func fail(_ client: FDChannel, _ status: Int, _ reason: String, html: Bool, name: String, error: String, hint: String,
                      page: String? = nil, retryAfter: Int? = nil) async {
        if html { await reply(client, status, reason, page ?? "<h1>\(Self.escape(error))</h1><p>\(Self.escape(hint))</p>", retryAfter: retryAfter) }
        else { await reply(client, status, reason, Self.jsonBody(error: error, name: name, hint: hint), json: true, retryAfter: retryAfter) }
    }

    static let headerTimeout: Duration = .seconds(30)

    /// Race this read against the header deadline established for the connection.
    /// Expiry closes the descriptor to unblock I/O; either result cancels the losing task.
    private func readWithTimeout(_ client: FDChannel, until deadline: ContinuousClock.Instant) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await client.read() }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); client.close(); throw CancellationError() }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// The only host destination is IPv4 loopback. Connect/poll runs on a dispatch worker, never an NIO event loop.
    private static func connectHost(port: Int) async throws -> FDChannel {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continuation.resume(throwing: POSIXError(.ENFILE)); return }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian; addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if rc != 0 {
                    var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                    guard errno == EINPROGRESS, poll(&ready, 1, 3000) > 0,
                          getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                        Darwin.close(fd); continuation.resume(throwing: POSIXError(.ECONNREFUSED)); return
                    }
                }
                continuation.resume(returning: FDChannel(fd: fd, label: "app.noodle.dev.upstream"))
            }
        }
    }

    private static func bridgeHost(_ client: FDChannel, _ upstream: FDChannel) async {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (from, to) in [(client, upstream), (upstream, client)] {
                    group.addTask {
                        do { while let data = try await from.read() { try await to.write(data) } }
                        catch { from.close(); to.close(); return }
                        to.shutdownWrite()
                    }
                }
                await group.waitForAll()
            }
        } onCancel: { client.close(); upstream.close() }
        client.close(); upstream.close()
    }

    private func reply(_ client: FDChannel, _ status: Int, _ reason: String, _ body: String, json: Bool = false, retryAfter: Int? = nil) async {
        let html = json ? body : """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Noodle</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:36rem;margin:3rem auto;padding:0 1.25rem;color:#222}code{background:#f0f0f0;padding:.1em .35em;border-radius:4px}ul{padding-left:1.25rem}@media(prefers-color-scheme:dark){body{background:#161616;color:#e8e8e8}code{background:#2a2a2a}}</style>
        </head><body>\(body)</body></html>
        """
        let fields = [
            "HTTP/1.1 \(status) \(reason)",
            json ? "Content-Type: application/json" : "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(html.utf8.count)",
            "Connection: close",
        ] + (retryAfter.map { ["Retry-After: \($0)"] } ?? []) + [
            "", "",
        ]
        let msg = fields.joined(separator: "\r\n") + html
        try? await client.write(Data(msg.utf8))
        client.shutdownWrite()
        client.close()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 34: out += "&quot;"
            case 38: out += "&amp;"
            case 60: out += "&lt;"
            case 62: out += "&gt;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
