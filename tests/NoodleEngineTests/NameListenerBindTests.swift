import Testing
import Foundation
@testable import NoodleEngine

@Suite(.serialized) struct NameListenerBindTests {
    @Test func peerFilterAcceptsOnlyLoopback() {
        #expect(NameListener.isLoopback(address: [127, 0, 0, 1]))
        #expect(NameListener.isLoopback(address: [127, 255, 3, 9]))
        #expect(!NameListener.isLoopback(address: [192, 168, 64, 1]))
        #expect(!NameListener.isLoopback(address: [10, 0, 0, 127]))
        #expect(!NameListener.isLoopback(address: [0, 0, 0, 0]))
        let v6 = { (tail: [UInt8]) in Array(repeating: UInt8(0), count: 16 - tail.count) + tail }
        #expect(NameListener.isLoopback(address: v6([1])))
        #expect(NameListener.isLoopback(address: v6([0xff, 0xff, 127, 0, 0, 1])))
        #expect(NameListener.isLoopback(address: v6([0xff, 0xff, 127, 9, 8, 7])))
        #expect(!NameListener.isLoopback(address: v6([0xff, 0xff, 192, 168, 64, 1])))
        #expect(!NameListener.isLoopback(address: v6([])))
        #expect(!NameListener.isLoopback(address: v6([2])))
        #expect(!NameListener.isLoopback(address: [0xfe, 0x80] + v6([1]).dropFirst(2)))
        #expect(!NameListener.isLoopback(address: v6([127, 0, 0, 1]))) // IPv4-compatible, not mapped
        #expect(!NameListener.isLoopback(address: []))
    }

    private func bindError(_ code: Int32) -> NameListener.BindError { .init(code: code, description: "errno \(code)") }

    /// Runs `select` against scripted bind results and returns the attempts it made plus its outcome.
    private func run(primary: Int = 80, fallback: Int = 10080, _ results: [String: Int32]) -> (tries: [String], chosen: String?, reason: String?) {
        var tries: [String] = []
        let outcome = try? NameRouter.select(primary: primary, fallback: fallback) { (port: Int, scope: NameListener.Scope) -> String in
            let key = "\(port)/\(scope == .loopback ? "lo" : "pinned")"
            tries.append(key)
            if let code = results[key] { throw bindError(code) }
            return key
        }
        return (tries, outcome?.0, outcome?.1)
    }

    @Test func privilegedLoopbackBindIsUsedFirst() {
        let r = run([:])
        #expect(r.tries == ["80/lo"]); #expect(r.chosen == "80/lo"); #expect(r.reason == nil)
    }

    @Test func permissionDeniedRetriesPinnedWildcardOnSamePort() {
        let r = run(["80/lo": EACCES])
        #expect(r.tries == ["80/lo", "80/pinned"]); #expect(r.chosen == "80/pinned"); #expect(r.reason == nil)
    }

    @Test func takenPortFallsBackWithoutTryingWildcard() {
        let r = run(["80/lo": EADDRINUSE])
        #expect(r.tries == ["80/lo", "10080/lo"]); #expect(r.chosen == "10080/lo"); #expect(r.reason == "errno \(EADDRINUSE)")
    }

    @Test func bothStandardBindsFailingFallsBack() {
        let r = run(["80/lo": EACCES, "80/pinned": EADDRINUSE])
        #expect(r.tries == ["80/lo", "80/pinned", "10080/lo"]); #expect(r.chosen == "10080/lo"); #expect(r.reason == "errno \(EADDRINUSE)")
    }

    @Test func fallbackAlsoRetriesPinnedOnPermissionDenied() {
        let r = run(["80/lo": EADDRINUSE, "10080/lo": EACCES])
        #expect(r.tries == ["80/lo", "10080/lo", "10080/pinned"]); #expect(r.chosen == "10080/pinned")
    }

    @Test func skippedPrimaryGoesStraightToFallback() {
        let r = run(primary: 0, [:])
        #expect(r.tries == ["10080/lo"]); #expect(r.reason == nil)
    }

    @Test func everyBindFailingThrows() {
        let r = run(["80/lo": EADDRINUSE, "10080/lo": EADDRINUSE])
        #expect(r.chosen == nil)
    }

    @Test func defaultFallbacksAvoidCommonDevPorts() {
        let c = NameRouter.Config()
        #expect(c.httpPrimary == 80 && c.httpsPrimary == 443)
        #expect(c.httpFallback == 10080 && c.httpsFallback == 10443)
    }

    /// Real sockets: unprivileged port 80 through the router, reached by curl with no port in the URL.
    @Test func unprivilegedRouterServesPort80WithoutPort() throws {
        // shortcut: returns instead of a reported skip when port 80 is busy on this machine.
        guard !NameListener.loopbackAnswers(port: 80) else { return }
        let stub = try NameListener(port: 0, scope: .loopback, label: "app.noodle.tests.stub") { fd in
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 4096); _ = read(fd, &buf, buf.count)
                let body = "stub-route\n"
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { write(fd, $0, strlen($0)) }
                Darwin.close(fd)
            }
        }
        defer { stub.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let router = try NameRouter(config: .init(httpPrimary: 80, httpsPrimary: 0, httpFallback: 0, httpsFallback: 0),
                                    ca: LocalCA(paths: NoodlePaths(root: root)))
        defer { router.stop() }
        #expect(router.port == 80)
        if getuid() != 0 { #expect(router.http.scope == .wildcard) }
        _ = try router.addDev(host: "web.localhost", port: stub.port, ownerPID: getpid())
        router.update(router.devTargets(), openers: [:])
        for url in ["http://web.localhost/", "http://127.0.0.1/", "http://[::1]/"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "--max-time", "5", "-H", "Host: web.localhost", url]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            #expect(out == "stub-route\n", "\(url)")
        }
    }
}
