import Foundation
import Testing
@testable import NoodleApp

/// One-shot unix server: answers any request with `total` body bytes (read-until-close) and records how many it wrote.
private final class BodyServer: @unchecked Sendable {
    let path = "/tmp/noodle-body-\(UUID().uuidString.prefix(8)).sock"
    let total: Int
    private let lock = NSLock()
    private var _written = 0
    private var _finished = false
    var written: Int { lock.withLock { _written } }
    var finished: Bool { lock.withLock { _finished } }
    private let fd: Int32

    init(total: Int) {
        self.total = total
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(bound == 0 && listen(fd, 1) == 0)
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        let c = accept(fd, nil, nil)
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = read(c, &buf, buf.count)
        let head = Array("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8)
        _ = write(c, head, head.count)
        let chunk = [UInt8](repeating: 120, count: 64 * 1024)
        while written < total {
            let n = write(c, chunk, min(chunk.count, total - written))
            if n <= 0 { break }
            lock.withLock { _written += n }
        }
        lock.withLock { _finished = _written == total }
        close(c)
    }

    deinit { close(fd); unlink(path) }
}

@Suite(.tags(.slow)) struct DockerSocketBodyTests {
    @Test func cappedRequestStillDrainsTheWholeBody() async throws {
        let server = BodyServer(total: 3 << 20)
        let r = try await DockerSocket(path: server.path).request("GET", "/x", timeout: 10, maxBody: 1 << 20)
        #expect(r.body.count == 1 << 20)
        #expect(server.finished, "the peer must be allowed to finish; closing early kills a running exec")
    }

    @Test func streamingReadsOnDemand() async throws {
        let server = BodyServer(total: 256 << 20)
        let stream = try await DockerSocket(path: server.path).stream("GET", "/x")
        var it = stream.makeAsyncIterator()
        _ = try await it.next()
        try await Task.sleep(for: .milliseconds(500)) // consumer stalls
        #expect(server.written < 32 << 20, "unread bytes must stay in kernel buffers, not pile up in the app")
    }
}

@Suite struct LogDemuxerBoundTests {
    @Test func endlessLineWithoutNewlineStaysBounded() {
        var d = LogDemuxer(tty: true, timestamps: false)
        var emitted = 0
        for _ in 0..<100 { emitted += d.feed(Data(repeating: 97, count: 16 * 1024)).count }
        #expect(emitted >= 20, "lines past the cap are emitted instead of retained")
        #expect(d.flush().map(\.text.utf8.count).reduce(0, +) <= LogDemuxer.maxPartialBytes)
    }

    @Test func ttyCharacterSplitAcrossReadsStaysWhole() {
        var d = LogDemuxer(tty: true, timestamps: false)
        let bytes = Array("héllo 🍜\nnext é".utf8)
        var out: [LogEntry] = []
        for b in bytes { out += d.feed(Data([b])) }   // worst case: one byte per read
        out += d.flush()
        #expect(out.map(\.text) == ["héllo 🍜", "next é"])
        #expect(d.feed(Data()).isEmpty)
    }

    @Test func logStreamKeepsOnlyTheNewestLinesWhenTheReaderLags() async throws {
        let (bytes, input) = AsyncThrowingStream<Data, Error>.makeStream()
        input.yield(Data((0..<6_000).map { "line \($0)\n" }.joined().utf8))
        input.finish()
        let entries = DockerAPI.logEntries(bytes, tty: true)
        try await Task.sleep(for: .milliseconds(300))   // the reader lags behind the producer
        var texts: [String] = []
        for try await e in entries { texts.append(e.text) }
        #expect(texts.count == 5_000)
        #expect(texts.last == "line 5999")
    }
}
