import Foundation
import NoodleCore
import NoodleEngine

extension Handlers {
    func build(_ req: Request, _ w: ResponseWriter) async throws {
        for key in ["remote", "session", "outputs", "extrahosts", "cachefrom", "ulimits", "isolation", "securityopt"] {
            if let value = req.string(key), !["", "[]", "{}", "default"].contains(value) {
                throw APIError(status: 400, message: "unsupported build option: \(key)")
            }
        }
        for key in ["memory", "memswap", "cpushares", "cpuperiod", "cpuquota", "cpusetcpus", "cpusetmems", "shmsize"] {
            if let value = req.string(key), !["", "0"].contains(value) {
                throw APIError(status: 400, message: "unsupported build resource limit: \(key)")
            }
        }
        guard req.string("version") != "2" else { throw APIError(status: 400, message: "use DOCKER_BUILDKIT=0 for local context builds") }
        func dictionary(_ key: String) throws -> [String: String] {
            guard let value = req.string(key) else { return [:] }
            guard let dict = try? JSONDecoder().decode([String: String?].self, from: Data(value.utf8)) else {
                throw APIError(status: 400, message: "invalid \(key)")
            }
            return dict.compactMapValues { $0 }
        }
        let options = try BuildOptions(dockerfile: req.string("dockerfile") ?? "Dockerfile", args: dictionary("buildargs"),
                                       labels: dictionary("labels"), tags: req.all("t"), target: req.string("target"),
                                       noCache: req.bool("nocache"), pull: req.bool("pull"), network: req.string("networkmode"),
                                       platform: req.string("platform"))
        let context = try await spoolBody(req, limit: Int64(BuildOptions.maximumContextBytes), message: BuildOptions.contextLimitMessage)
        defer { context.remove() }
        try await w.beginStream(contentType: Self.jsonStream)
        do {
            let quiet = req.bool("q")
            let id = try await engine.buildImage(context: context.url, options: options) { message in
                if !quiet {
                    do { try await w.writeJSON(["stream": message]) }
                    catch is ConnectionClosed { throw CancellationError() }
                }
            }
            try await w.writeJSON(["aux": ["ID": id]])
            try await w.writeJSON(["stream": quiet ? id + "\n" : "Successfully built \(id.dropFirst(7).prefix(12))\n"])
        } catch {
            if error is CancellationError || error is ConnectionClosed { throw error }
            let (_, message) = ErrorMap.describe(error)
            try await w.writeJSON(ErrorLine(errorDetail: .init(message: message), error: message))
        }
    }
}

extension Handlers {
    func nativeBuildConnection(_ req: Request, _ w: ResponseWriter, mode: String, adapter: BuildKitAdapter? = nil) async throws {
        guard req.headers.first(name: "Upgrade")?.lowercased() == "h2c" else {
            throw APIError(status: 400, message: "BuildKit requires an h2c upgrade")
        }
        var headers: [String: [String]] = [:]
        for (name, value) in req.headers where name.lowercased().hasPrefix("x-docker-expose-session-") {
            headers[name.lowercased(), default: []].append(value)
        }
        struct Hello: Encodable { var mode: String; var headers: [String: [String]] }
        let hello = try JSONEncoder().encode(Hello(mode: mode, headers: headers)) + Data([10])
        guard hello.count <= 64000 else { throw APIError(status: 400, message: "excessive session metadata") }
        // A session is already build traffic. A /grpc request can instead be a
        // capability probe that closes after 101 without sending HTTP/2 bytes.
        if mode != "grpc" { _ = try await engine.prepareNativeBuildAdapter(using: adapter) }
        let raw = try await w.hijack(contentType: "application/grpc", protocolName: "h2c")
        defer { raw.close() }
        // Buildx probes support by upgrading and immediately closing without sending bytes.
        let first: Data
        if mode == "grpc" {
            guard let bytes = try await raw.inbox.next() else { return }
            first = Data(bytes.readableBytesView)
        } else { first = Data() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            if let peerEOF = raw.peerEOF { group.addTask { for await _ in peerEOF {} } }
            group.addTask {
                if mode == "grpc" {
                    do { _ = try await self.engine.prepareNativeBuildAdapter(using: adapter) }
                    catch {
                        if error is CancellationError || error is ConnectionClosed { throw error }
                        // JSON would corrupt an upgraded connection, so answer in HTTP/2.
                        try await Self.nativeBuildStartupFailure(ErrorMap.describe(error).1, raw: raw, first: first)
                        return
                    }
                }
                try await self.engine.withNativeBuildConnection { stream in
                    try await stream.write(hello + first)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            while let b = try await raw.inbox.next() { try await stream.write(Data(b.readableBytesView)) }
                        }
                        group.addTask {
                            while let data = try await stream.readChunk() { try await raw.write(data) }
                        }
                        defer { raw.close(); stream.close(); group.cancelAll() }
                        _ = try await group.next()
                    }
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Answers the client's first RPC with grpc-status UNAVAILABLE. A GOAWAY or
    /// HTTP error is a connection failure, which grpc-go retries silently under
    /// WaitForReady (buildx ListWorkers), so only a real RPC status reaches the user.
    static func nativeBuildStartupFailure(_ message: String, raw: RawConnection, first: Data) async throws {
        var out = Data([0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0]) // SETTINGS, then ACK of the client's
        var buffer = first.starts(with: Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)) ? Data(first.dropFirst(24)) : first
        try await raw.write(out)
        while true {
            while buffer.count >= 9 {
                let b = Array(buffer.prefix(9))
                let length = Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
                guard buffer.count >= 9 + length else { break }
                buffer = Data(buffer.dropFirst(9 + length))
                guard b[3] == 1 else { continue } // first HEADERS frame opens the RPC
                func string(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) } // under 127 bytes
                let escaped = Data(message.utf8.prefix(2048)).map { $0 >= 0x20 && $0 < 0x7f && $0 != 0x25 ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
                var block: [UInt8] = [0x88, 0x0f, 0x10] + string("application/grpc") // :status 200, content-type
                block += [0] + string("grpc-status") + string("14") // UNAVAILABLE
                var size = escaped.utf8.count, encoded: [UInt8] = []
                if size < 127 { encoded = [UInt8(size)] } else {
                    encoded = [127]; size -= 127
                    while size >= 128 { encoded.append(UInt8(size & 127 | 128)); size >>= 7 }
                    encoded.append(UInt8(size))
                }
                block += [0] + string("grpc-message") + encoded + Array(escaped.utf8)
                out = Data([UInt8(block.count >> 16), UInt8((block.count >> 8) & 255), UInt8(block.count & 255), 1, 5]) + Data(b[5..<9]) + Data(block)
                try await raw.write(out)
                return
            }
            guard buffer.count < 65536, let more = try await raw.inbox.next() else { return }
            buffer.append(contentsOf: more.readableBytesView)
        }
    }
}

extension Handlers {
    func nativeBuildHistory(_ req: Request, _ w: ResponseWriter) async throws {
        guard let token = req.headers.first(name: "X-Noodle-Build-Token"), token.count == 36 else {
            throw APIError(status: 403, message: "missing build capability")
        }
        let data = try await req.body.readAll(limit: 16 << 20)
        try await engine.recordNativeBuildHistory(token: token, data: data)
        try await w.json(["ok": true])
    }
}
