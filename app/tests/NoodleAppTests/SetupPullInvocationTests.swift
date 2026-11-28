import Darwin
import Foundation
import Testing
@testable import NoodleApp

@Suite struct SetupPullInvocationTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pull-\(UUID()).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test(arguments: [false, true]) func ignoringTermCannotHoldCancellation(timeout: Bool) async throws {
        // A watchdog lets the regression fail in bounded time even with the old runner; its marker says it had to step in.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pull-watchdog-\(UUID())")
        let url = try script("trap '' TERM\n(sleep 20; touch '\(marker.path)'; kill -KILL $$) >/dev/null 2>&1 &\necho ready\nwhile :; do sleep 1; done\n")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: marker) }
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            return await CLI.stream(executable: url.path, [], environment: ProcessInfo.processInfo.environment,
                             timeout: timeout ? 1 : 10) { line in
                if line == "ready" { ready.continuation.yield(()) }
            }
        }
        defer { task.cancel(); ready.continuation.finish() }
        for await _ in ready.stream { break }
        if !timeout { task.cancel() }
        let result = await task.value
        #expect(result.code == (timeout ? 124 : 130))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the runner waited for the watchdog to kill the script")
        #expect(result.output.contains("ready"))
    }

    @Test func descendantHoldingOutputCannotHoldCompletion() async throws {
        // The descendant keeps stdout open and leaves a marker if it lives long enough to finish.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("pull-descendant-\(UUID())")
        let url = try script("trap '' TERM\n(sleep 20; touch '\(marker.path)') &\necho $!\necho final-line\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: marker) }
        let result = await CLI.stream(executable: url.path, [], environment: ProcessInfo.processInfo.environment,
                                      timeout: 1) { _ in }
        #expect(result.code == 7)
        #expect(result.output.contains("final-line"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "completion waited for the descendant to finish")
        let pid = try #require(result.output.split(separator: "\n").first.flatMap { pid_t($0) })
        defer { kill(pid, SIGKILL) }
        #expect(try await waitUntil(timeout: .seconds(5)) { kill(pid, 0) == -1 && errno == ESRCH })
    }

    @Test func partialLinesAndExitCodeSurvive() async throws {
        let url = try script("printf 'out\\rprogress\\n'; printf err >&2; exit 3\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await CLI.stream(executable: url.path, [], environment: ["PATH": "/usr/bin:/bin"], timeout: 2) { _ in }
        #expect(result.code == 3)
        #expect(result.output == "out\rprogress\nerr")
    }

    @Test func cancelledBeforeLaunchDoesNotRun() async throws {
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CLI.stream(executable: "/bin/echo", ["must-not-run"], environment: [:], timeout: 1) { _ in }
        }.value
        #expect(result.code == 130)
        #expect(!result.output.contains("must-not-run"))
    }
}
