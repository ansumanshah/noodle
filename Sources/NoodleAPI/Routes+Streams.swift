import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func streamRoutes(_ t: inout RouteTable) {
        let engine = self.engine

        t.get("containers/{id}/logs") { req, w in
            var o = LogOptions()
            o.follow = req.bool("follow"); o.stdout = req.bool("stdout"); o.stderr = req.bool("stderr")
            o.since = req.seconds("since") ?? 0; o.until = req.seconds("until") ?? 0; o.timestamps = req.bool("timestamps")
            if let tail = req.string("tail"), tail != "all" { o.tail = Int(tail) ?? -1 }
            guard o.stdout || o.stderr else { throw APIError(status: 400, message: "no log output requested: set stdout=true or stderr=true") }
            let info = try await engine.inspectContainer(req.param("id"))
            let tty = info.Config.Tty
            let stream = try await engine.logs(req.param("id"), options: o)
            defer { stream.close() }
            try await w.beginStream(contentType: tty || !req.api(atLeast: "1.42") ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
            while let f = try await stream.nextFrame() {
                if f.kind == .exit { break }
                guard (f.kind == .stdout && o.stdout) || (f.kind == .stderr && o.stderr) else { continue }
                if tty { try await w.write(f.payload) } else { try await w.write(Self.muxFrame(f.kind == .stdout ? 1 : 2, f.payload)) }
            }
        }

        t.post("containers/{id}/attach") { req, w in
            let id = req.param("id")
            let tty = try await engine.containerUsesTTY(id)
            let wantIn = req.bool("stdin"), wantOut = req.bool("stdout"), wantErr = req.bool("stderr")
            let stream = try await engine.attach(id, stdin: wantIn, stdout: wantOut, stderr: wantErr, logs: req.bool("logs"))
            defer { stream.close() }
            let conn = try await w.hijack(contentType: tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
            await Bridge.run(stream: stream, conn: conn, tty: tty, stdin: wantIn, stdout: wantOut, stderr: wantErr)
        }
        t.get("containers/{id}/attach/ws") { _, _ in throw APIError(status: 501, message: "websocket attach is not supported by Noodle") }

        t.get("containers/{id}/stats") { req, w in
            let oneShot = req.bool("one-shot")
            let streaming = req.bool("stream", true) && !oneShot
            let id = req.param("id")
            let samples = try await engine.stats(id, stream: streaming, oneShot: oneShot)
            if streaming {
                try await w.beginStream(contentType: Self.jsonStream)
                for try await s in samples { try await w.writeJSON(s) }
            } else {
                for try await s in samples { try await w.json(s); return }
                throw APIError(status: 500, message: "no stats sample")
            }
        }

        t.get("containers/{id}/export") { req, w in
            let stream = try await engine.exportContainer(req.param("id"))
            defer { stream.close() }
            try await w.beginStream(contentType: "application/x-tar")
            while let c = try await stream.readChunk() { try await w.write(c) }
        }

        t.head("containers/{id}/archive") { req, w in
            let stream = try await engine.archiveGet(req.param("id"), path: req.string("path") ?? "")
            defer { stream.close() }
            let stat = try await Self.statHeader(stream, req)
            try await w.send(.ok, contentType: "application/x-tar", headers: [("X-Docker-Container-Path-Stat", stat.header)])
        }
        t.get("containers/{id}/archive") { req, w in
            let stream = try await engine.archiveGet(req.param("id"), path: req.string("path") ?? "")
            defer { stream.close() }
            let stat = try await Self.statHeader(stream, req)
            try await w.beginStream(contentType: "application/x-tar", headers: [("X-Docker-Container-Path-Stat", stat.header)])
            try await w.write(stat.first)
            while let c = try await stream.readChunk() { try await w.write(c) }
        }
        t.put("containers/{id}/archive") { req, w in
            let id = req.param("id"), path = req.string("path") ?? ""
            var spool: Spool?
            var size: Int64
            if let cl = req.headers.first(name: "Content-Length").flatMap({ Int64($0) }) {
                size = cl
            } else {
                // Chunked upload: the guest needs the exact size up front, so spool to disk first.
                let s = try await spoolBody(req)
                size = s.size; spool = s
            }
            defer { spool?.remove() }
            let stream = try await engine.archivePut(id, path: path, size: size, copyUIDGID: req.bool("copyUIDGID"))
            defer { stream.close() }
            if let spool { try await stream.send(file: spool.url) }
            else {
                while let b = try await req.body.next() { try await stream.write(Data(b.readableBytesView)) }
            }
            stream.finishWriting()
            _ = try await stream.readResult()
            try await w.empty(.ok)
        }
    }

    static func muxFrame(_ stream: UInt8, _ payload: Data) -> Data {
        var d = Data(capacity: payload.count + 8)
        d.append(contentsOf: [stream, 0, 0, 0])
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    /// Read an archive stream up to its first real tar entry and build the stat header from it.
    static func statHeader(_ stream: GuestStream, _ req: Request) async throws -> (header: String, first: Data) {
        var head = Data()
        var found: PathStat?
        while found == nil, head.count < Engine.maxTarStatPrefix, let c = try await stream.readChunk() {
            head.append(c)
            found = Engine.pathStat(fromTarHeader: head)
        }
        guard let stat = found else {
            throw APIError(status: 404, message: "Could not find the file \(req.string("path") ?? "") in container \(req.param("id"))")
        }
        let json = try JSONOut.encode(stat)
        return (json.base64EncodedString(), head)
    }
}

/// Request body spooled to a temporary file.
final class Spool {
    /// Bytes held on disk by all live spools in this process, so parallel uploads share one free-disk allowance.
    static let inFlight = NIOLockedValueBox<Int64>(0)
    let url: URL
    private let handle: FileHandle
    private(set) var size: Int64 = 0
    /// Appends beyond this many bytes fail with 413. The file is removed by the caller's `remove()`.
    let limit: Int64
    private let message: String
    /// Free-disk allowance right now; nil when this spool is not disk-capped.
    private let free: (() -> Int64)?
    private let ledger: NIOLockedValueBox<Int64>
    /// Cached shared budget: free disk plus what live spools already wrote. Re-measured only when it runs out.
    private var budget: Int64 = 0

    init(dir: URL, limit: Int64 = .max, message: String = UploadLimits.exceededMessage,
         free: (() -> Int64)? = nil, ledger: NIOLockedValueBox<Int64> = Spool.inFlight) throws {
        self.limit = limit; self.message = message; self.free = free; self.ledger = ledger
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("api-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ b: ByteBuffer) throws {
        let n = Int64(b.readableBytes)
        guard n <= limit - size else { throw APIError(status: 413, message: message) }
        let fits = ledger.withLockedValue { total -> Bool in
            if let free, n > budget - total { budget = free() + total }
            guard free == nil || n <= budget - total else { return false }
            total += n
            return true
        }
        guard fits else { throw APIError(status: 413, message: UploadLimits.exceededMessage) }
        do { try handle.write(contentsOf: Data(b.readableBytesView)) } catch {
            ledger.withLockedValue { $0 -= n }
            throw error
        }
        size += n
    }
    func close() throws { try handle.close() }
    func remove() {
        try? handle.close(); try? FileManager.default.removeItem(at: url)
        let held = size
        ledger.withLockedValue { $0 -= held }
        size = 0
    }
}

extension Handlers {
    /// Spool a request body to a temp file under the upload limit. Refuses early on a declared oversize length and
    /// removes the file when the body fails, is cut short, or is cancelled.
    /// `limit` and `message` tighten the cap below the free-disk allowance (the stricter wins).
    func spoolBody(_ req: Request, limit: Int64 = .max, message: String = UploadLimits.exceededMessage) async throws -> Spool {
        let dir = engine.paths.tmpDir
        let allowance = min(UploadLimits.allowance(in: dir), limit)
        if let n = req.headers.first(name: "Content-Length").flatMap(Int64.init), n > allowance {
            throw APIError(status: 413, message: allowance == limit ? message : UploadLimits.exceededMessage)
        }
        let spool = try Spool(dir: dir, limit: allowance, message: allowance == limit ? message : UploadLimits.exceededMessage,
                              free: { UploadLimits.allowance(in: dir) })
        do {
            while let b = try await req.body.next() { try Task.checkCancellation(); try spool.append(b) }
            try spool.close()
            return spool
        } catch { spool.remove(); throw error }
    }
}
