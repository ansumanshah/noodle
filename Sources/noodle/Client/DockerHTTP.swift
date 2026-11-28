import Foundation

// The CLI's one blocking HTTP client over a unix socket: the engine, other engines during import, and probes.
// Streams bodies to a sink or from a file so multi-gigabyte images never sit in memory.

struct ImportError: Error, CustomStringConvertible, ExitCoded {
    let message: String
    let retryable: Bool
    var exitCode: Int32 = ExitCode.failure
    /// The socket stopped answering within the client's timeout.
    var timedOut = false
    var description: String { message }
    static func fatal(_ m: String) -> ImportError { ImportError(message: m, retryable: false) }
    static func transient(_ m: String) -> ImportError { ImportError(message: m, retryable: true) }
    static func usage(_ m: String) -> ImportError { ImportError(message: m, retryable: false, exitCode: ExitCode.usage) }
    /// The Noodle engine's own socket refused the connection.
    static func engineDown(_ m: String) -> ImportError { ImportError(message: m, retryable: true, exitCode: ExitCode.engineDown) }
}

enum RequestBody { case none, data(Data), file(URL) }

struct HTTPReply {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Test hook: the first streamed download that passes this many bytes is cut, as if the source dropped.
nonisolated(unsafe) var importFaultBytes: Int? = ProcessInfo.processInfo.environment["NOODLE_IMPORT_FAULT_AFTER_BYTES"].flatMap(Int.init)

final class DockerHTTP {
    let socketPath: String
    let cancellation: ImportCancellation?
    /// Seconds each read or write may wait; nil keeps import's defaults (5 s protected, else 300 s).
    let timeout: Int?
    init(socketPath: String, cancellation: ImportCancellation? = nil, timeout: Int? = nil) {
        self.socketPath = socketPath; self.cancellation = cancellation; self.timeout = timeout
    }
    private var waitSeconds = 0

    private var fd: Int32 = -1
    private var buffer = [UInt8]()
    private var pos = 0

    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: RequestBody = .none,
                 sink: ((Data) throws -> Void)? = nil) throws -> HTTPReply {
        try cancellation?.check()
        defer {
            if fd >= 0 { if let cancellation { cancellation.closeSocket(fd) } else { close(fd) } }
            fd = -1; buffer = []; pos = 0
        }
        try connect()
        var length = 0
        switch body {
        case .none: break
        case .data(let d): length = d.count
        case .file(let url):
            length = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if case .none = body, method == "GET" || method == "DELETE" {} else { head += "Content-Length: \(length)\r\n" }
        try send(Data((head + "\r\n").utf8))
        switch body {
        case .none: break
        case .data(let d): try send(d)
        case .file(let url):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var left = length
            while left > 0, let chunk = try h.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty {
                left -= chunk.count
                if left == 0, let cancellation {
                    // Let the engine acknowledge the final chunk before rollback can race its commit.
                    return try cancellation.finish { setTimeout(30); try send(chunk); return try readReply(sink: sink) }
                }
                try send(chunk)
            }
            guard left == 0 else { throw ImportError.fatal("upload file ended with \(left) bytes missing") }
        }
        return try readReply(sink: sink)
    }

    private func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ImportError.fatal("socket() failed") }
        try cancellation?.attach(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(timeout ?? (cancellation?.isProtected == true ? 5 : 300))
        guard let connected = Self.connect(fd, path: socketPath) else { throw ImportError.fatal("socket path too long: \(socketPath)") }
        if !connected {
            let reason = String(cString: strerror(errno))
            let message = "cannot connect to \(socketPath): \(reason)"
            throw socketPath == paths.socket.path ? ImportError.engineDown(message) : ImportError.transient(message)
        }
    }

    /// Connects `fd` to the unix socket at `path`. Nil when the path is too long; false leaves errno set.
    static func connect(_ fd: Int32, path: String) -> Bool? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func ioError(_ verb: String) -> ImportError {
        if errno == EAGAIN {
            return ImportError(message: "\(socketPath) did not answer within \(waitSeconds) seconds", retryable: true, timedOut: true)
        }
        return .transient("\(verb) \(socketPath) failed: \(String(cString: strerror(errno)))")
    }

    private func setTimeout(_ seconds: Int) {
        waitSeconds = seconds
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                try cancellation?.check()
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw ioError("write to") }
                off += n
            }
        }
    }

    /// Next bytes from the socket, or nil at end of stream.
    private func fill() throws -> Bool {
        try cancellation?.check()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 { throw ioError("read from") }
        if n == 0 { return false }
        if pos > 0 { buffer.removeFirst(pos); pos = 0 }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    private func readLine() throws -> String {
        while true {
            if let i = buffer[pos...].firstIndex(of: 10) {
                let line = String(decoding: buffer[pos..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                pos = i + 1
                return line
            }
            guard try fill() else { throw ImportError.transient("connection closed mid-response") }
        }
    }

    private func readExact(_ n: Int, _ deliver: (Data) throws -> Void) throws {
        var left = n
        while left > 0 {
            try cancellation?.check()
            if pos == buffer.count, !(try fill()) { throw ImportError.transient("connection closed with \(left) bytes missing") }
            let take = min(left, buffer.count - pos)
            try deliver(Data(buffer[pos..<pos + take]))
            pos += take; left -= take
        }
    }

    private func readReply(sink: ((Data) throws -> Void)?) throws -> HTTPReply {
        let status = try readLine().split(separator: " ")
        guard status.count >= 2, let code = Int(status[1]) else { throw ImportError.transient("bad response from \(socketPath)") }
        var headers: [String: String] = [:]
        while true {
            let line = try readLine()
            if line.isEmpty { break }
            if let c = line.firstIndex(of: ":") {
                headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var reply = HTTPReply(status: code, headers: headers, body: Data())
        let streaming = sink != nil && (200..<300).contains(code)
        var delivered = 0
        let deliver: (Data) throws -> Void = { d in
            if streaming {
                try sink!(d)
                delivered += d.count
                if let cut = importFaultBytes, delivered >= cut {
                    importFaultBytes = nil
                    throw ImportError.transient("injected connection drop after \(delivered) bytes")
                }
            } else { reply.body.append(d) }
        }
        if code == 204 || code == 304 { return reply }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                let size = Int(try readLine().split(separator: ";").first.map(String.init) ?? "", radix: 16) ?? -1
                if size < 0 { throw ImportError.transient("bad chunk header") }
                if size == 0 { break }
                try readExact(size, deliver)
                _ = try readLine()
            }
        } else if let n = headers["content-length"].flatMap(Int.init) {
            try readExact(n, deliver)
        } else {
            while true {
                if pos < buffer.count { try deliver(Data(buffer[pos...])); pos = buffer.count }
                if !(try fill()) { break }
            }
            // No length and no chunking: EOF cannot tell a finished stream from a cut one.
            if streaming { throw ImportError.transient("response to \(socketPath) has no length; cannot confirm it completed") }
        }
        return reply
    }
}

/// One GET to the Noodle engine; nil when it cannot be reached or answers badly.
func httpGet(_ target: String, timeoutSeconds: Int = 3) -> (status: Int, body: Data)? {
    guard let reply = try? DockerHTTP(socketPath: socketPath, timeout: timeoutSeconds).request("GET", target) else { return nil }
    return (reply.status, reply.body)
}
