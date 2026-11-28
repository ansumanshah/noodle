import Foundation
import NIOHTTP1
import NoodleEngine

extension Handlers {
    func execRoutes(_ t: inout RouteTable) {
        let engine = self.engine
        t.post("containers/{id}/exec") { req, w in
            struct Out: Encodable { var Id: String }
            let cfg = try await req.json(ExecConfig.self) ?? ExecConfig()
            try await w.json(Out(Id: try await engine.createExec(req.param("id"), config: cfg)), status: .created)
        }
        t.get("exec/{id}/json") { req, w in try await w.json(try await engine.inspectExec(req.param("id"))) }
        t.post("exec/{id}/resize") { req, w in
            try await engine.resizeExec(req.param("id"), rows: req.int("h") ?? 0, cols: req.int("w") ?? 0); try await w.empty(.ok)
        }
        t.post("exec/{id}/start") { req, w in
            struct Start: Decodable { var Detach: Bool?; var Tty: Bool? }
            let body = try await req.json(Start.self)
            let id = req.param("id")
            let detach = body?.Detach ?? false
            let info = try await engine.inspectExec(id)
            let tty = body?.Tty ?? info.ProcessConfig.tty
            let started: GuestStream?
            do {
                started = try await engine.startExec(id, detach: detach, tty: tty)
            } catch let failure as GuestError where !detach {
                // As Docker does: upgrade first and print the failure, because the CLI discards an error body here.
                let conn = try await w.hijack()
                let text = Data((failure.message + "\r\n").utf8)
                if tty { try await conn.write(text) } else { try await conn.writeMux(stream: 2, text) }
                conn.closeOutput()
                conn.close()
                return
            }
            guard let stream = started else {
                try await w.empty(.ok); return
            }
            defer { stream.close() }
            let conn = try await w.hijack()
            await Bridge.run(stream: stream, conn: conn, tty: tty, stdin: info.OpenStdin, stdout: true, stderr: true)
        }
    }
}

/// Copies between a guest multiplexed stream and a hijacked client connection.
enum Bridge {
    static func run(stream: GuestStream, conn: RawConnection, tty: Bool, stdin: Bool, stdout: Bool, stderr: Bool) async {
        let input: Task<Void, Never>? = stdin ? Task {
            do {
                while let chunk = try await conn.inbox.next() { try await stream.writeStdin(Data(chunk.readableBytesView)) }
                try await stream.closeStdin()   // client half-closed: stdin EOF, output keeps flowing
            } catch {}
        } : nil
        do {
            while let frame = try await stream.nextFrame() {
                switch frame.kind {
                case .stdout where stdout, .stderr where stderr:
                    if tty { try await conn.write(frame.payload) }
                    else { try await conn.writeMux(stream: frame.kind == .stdout ? 1 : 2, frame.payload) }
                case .exit: break
                default: continue
                }
                if frame.kind == .exit { break }
            }
        } catch {}
        input?.cancel()
        await input?.value
        conn.closeOutput()
        conn.close()
    }
}
