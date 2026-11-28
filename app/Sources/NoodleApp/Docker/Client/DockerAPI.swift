import Foundation

struct DockerAPI: Sendable {
    let socket: DockerSocket
    init(path: String) { socket = DockerSocket(path: path) }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))) ?? s }

    private func json<T: Decodable>(_ type: T.Type, _ target: String, timeout: Double = 20) async throws -> T {
        let r = try await socket.request("GET", target, timeout: timeout)
        guard r.status < 300 else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
        return try JSONDecoder().decode(T.self, from: r.body)
    }

    private func act(_ method: String, _ target: String, body: Data? = nil, timeout: Double = 60) async throws {
        let r = try await socket.request(method, target, body: body, timeout: timeout)
        guard r.status < 300 || r.status == 304 else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
    }

    // MARK: reads
    func ping() async throws {
        let r = try await socket.request("GET", "/_ping", timeout: 3)
        guard r.status == 200 else { throw HTTPFailure(status: r.status, message: "Daemon unhealthy") }
    }
    func info() async throws -> DaemonInfo { try await json(DaemonInfo.self, "/info", timeout: 5) }
    func vmStatus() async throws -> VMReadiness? { try await json(VMReadiness.self, "/noodle/vm/status?usage=1", timeout: 3) }
    func containers() async throws -> [ContainerSummary] { try await json([ContainerSummary].self, "/containers/json?all=1") }
    func inspect(_ id: String) async throws -> ContainerDetails { try await json(ContainerDetails.self, "/containers/\(enc(id))/json") }
    func images() async throws -> [ImageSummary] { try await json([ImageSummary].self, "/images/json") }
    static func imageSearchTarget(_ term: String) -> String {
        // Only RFC 3986 unreserved characters may pass through a query value.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "/images/search?term=\(encoded)&limit=25"
    }
    func searchImages(_ term: String) async throws -> [ImageSearchResult] {
        let results = try await json([ImageSearchResult].self, Self.imageSearchTarget(term))
        return Array(results.prefix(25))
    }
    func imageHistory(_ id: String) async throws -> [ImageHistory] { try await json([ImageHistory].self, "/images/\(enc(id))/history") }
    func volumes() async throws -> [VolumeSummary] {
        struct R: Decodable { var Volumes: [VolumeSummary]? }
        return try await json(R.self, "/volumes").Volumes ?? []
    }
    func networks() async throws -> [NetworkSummary] { try await json([NetworkSummary].self, "/networks") }

    // MARK: actions
    func start(_ id: String) async throws { try await act("POST", "/containers/\(enc(id))/start") }
    func stop(_ id: String) async throws { try await act("POST", "/containers/\(enc(id))/stop?t=10", timeout: 30) }
    func restart(_ id: String) async throws { try await act("POST", "/containers/\(enc(id))/restart?t=10", timeout: 30) }
    func removeContainer(_ id: String) async throws { try await act("DELETE", "/containers/\(enc(id))?force=1&v=0") }
    func removeImage(_ id: String) async throws { try await act("DELETE", "/images/\(enc(id))") }
    func removeVolume(_ name: String) async throws { try await act("DELETE", "/volumes/\(enc(name))") }
    func removeNetwork(_ id: String) async throws { try await act("DELETE", "/networks/\(enc(id))") }

    // MARK: streams
    func events() async throws -> AsyncThrowingStream<DockerEvent, Error> {
        let bytes = try await socket.stream("GET", "/events")
        return AsyncThrowingStream { cont in
            let task = Task {
                var lines = LineSplitter()
                do {
                    for try await chunk in bytes {
                        for line in lines.feed(chunk) {
                            if let e = try? JSONDecoder().decode(DockerEvent.self, from: line) { cont.yield(e) }
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func logs(_ id: String, tty: Bool, tail: Int = 400) async throws -> AsyncThrowingStream<LogEntry, Error> {
        let bytes = try await socket.stream("GET", "/containers/\(enc(id))/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=\(tail)")
        return Self.logEntries(bytes, tty: tty)
    }

    /// Keeps at most the 5,000 newest lines the logs view holds, so a chatty container cannot outrun the UI into unbounded memory.
    nonisolated static func logEntries(_ bytes: AsyncThrowingStream<Data, Error>, tty: Bool) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(5_000)) { cont in
            let task = Task {
                var demux = LogDemuxer(tty: tty)
                do {
                    for try await chunk in bytes {
                        for e in demux.feed(chunk) { cont.yield(e) }
                    }
                    for e in demux.flush() { cont.yield(e) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error> {
        let bytes = try await socket.stream("GET", "/containers/\(enc(id))/stats?stream=1")
        return AsyncThrowingStream { cont in
            let task = Task {
                var lines = LineSplitter()
                var n = 0
                do {
                    for try await chunk in bytes {
                        for line in lines.feed(chunk) {
                            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                            n += 1
                            cont.yield(Self.sample(obj, index: n))
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func statsSnapshot(_ id: String) async throws -> StatsSample? {
        let response = try await socket.request("GET", "/containers/\(enc(id))/stats?stream=false", timeout: 5)
        guard response.status == 200 else {
            throw HTTPFailure(status: response.status, message: DockerSocket.errorMessage(response.body))
        }
        guard let data = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { return nil }
        return Self.sample(data, index: 0)
    }

    static func sample(_ o: [String: Any], index: Int) -> StatsSample {
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        let cpu = o["cpu_stats"] as? [String: Any] ?? [:]
        let pre = o["precpu_stats"] as? [String: Any] ?? [:]
        let cu = cpu["cpu_usage"] as? [String: Any] ?? [:]
        let pu = pre["cpu_usage"] as? [String: Any] ?? [:]
        let dCPU = num(cu["total_usage"]) - num(pu["total_usage"])
        let dSys = num(cpu["system_cpu_usage"]) - num(pre["system_cpu_usage"])
        let ncpu = max(1, num(cpu["online_cpus"]))
        let pct = dSys > 0 && dCPU > 0 ? dCPU / dSys * ncpu * 100 : 0
        let mem = o["memory_stats"] as? [String: Any] ?? [:]
        let cache = ((mem["stats"] as? [String: Any])?["inactive_file"]).map(num) ?? 0
        var rx = 0.0, tx = 0.0
        for (_, v) in (o["networks"] as? [String: Any]) ?? [:] {
            let n = v as? [String: Any] ?? [:]
            rx += num(n["rx_bytes"]); tx += num(n["tx_bytes"])
        }
        let pids = num((o["pids_stats"] as? [String: Any])?["current"])
        return StatsSample(id: index, cpuPercent: pct, memoryBytes: Int(max(0, num(mem["usage"]) - cache)),
                           memoryLimit: Int(num(mem["limit"])), netRx: Int(rx), netTx: Int(tx), pids: Int(pids))
    }

    // MARK: exec
    static let maxExecOutput = 1 << 20
    struct ExecResult: Sendable { var output: String; var exitCode: Int? }

    /// Runs `argv` in the container to completion and returns combined output.
    func exec(_ id: String, argv: [String], timeout: Double = 30) async throws -> ExecResult {
        let create: [String: Any] = ["Cmd": argv, "AttachStdout": true, "AttachStderr": true, "Tty": false]
        let r = try await socket.request("POST", "/containers/\(enc(id))/exec", body: try JSONSerialization.data(withJSONObject: create), timeout: 15)
        guard r.status < 300, let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let execID = obj["Id"] as? String
        else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
        let start = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": false])
        let s = try await socket.request("POST", "/exec/\(execID)/start", body: start, timeout: timeout, upgrade: true,
                                    maxBody: Self.maxExecOutput + 1 << 16)
        guard s.status < 300 else { throw HTTPFailure(status: s.status, message: DockerSocket.errorMessage(s.body)) }
        var demux = LogDemuxer(tty: false, timestamps: false)
        var text = ""
        // Cap the text: a command that prints without end must not fill memory.
        for e in demux.feed(s.body) + demux.flush() {
            text += e.text + "\n"
            if text.utf8.count > Self.maxExecOutput { text += "\n[output truncated at 1 MB]\n"; break }
        }
        let insp = try? await socket.request("GET", "/exec/\(execID)/json", timeout: 5)
        let code = insp.flatMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["ExitCode"] as? Int }
        return ExecResult(output: text, exitCode: code)
    }

    // MARK: files
    /// Fetches the tar for a path (file or directory).
    func archive(_ id: String, path: String) async throws -> Data {
        let r = try await socket.request("GET", "/containers/\(enc(id))/archive?path=\(enc(path))", timeout: 120)
        guard r.status < 300 else { throw HTTPFailure(status: r.status, message: DockerSocket.errorMessage(r.body)) }
        return r.body
    }

    func archiveStream(_ id: String, path: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await socket.stream("GET", "/containers/\(enc(id))/archive?path=\(enc(path))")
    }

    /// One-level directory listing. `ls` through exec is O(directory); a tar of "/" would be the whole rootfs.
    func list(_ id: String, path: String) async throws -> [FileEntry] {
        let res = try await exec(id, argv: ["ls", "-1Ap", path], timeout: 15)
        guard let code = res.exitCode else { throw HTTPFailure(status: 0, message: "Could not determine whether the directory listing completed.") }
        if code != 0 { throw HTTPFailure(status: 0, message: res.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Self.parseListing(res.output, path: path)
    }

    /// A listing name comes from the container, so it must be one plain path component.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains { $0 == "/" || $0 == "\0" }
    }

    static func parseListing(_ output: String, path: String) -> [FileEntry] {
        let base = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { raw in
            let isDir = raw.hasSuffix("/")
            let name = isDir ? String(raw.dropLast()) : raw
            return FileEntry(path: base + name, name: name, isDirectory: isDir)
        }.filter { isSafeName($0.name) }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}
