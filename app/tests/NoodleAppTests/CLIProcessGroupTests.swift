import Foundation
import Testing
@testable import NoodleApp

/// da39649: a CLI timeout or cancel kills the whole process group, so a Docker child of the CLI dies too.
@Suite(.tags(.slow)) struct CLIProcessGroupTests {
    /// A fake CLI that starts a long-lived grandchild, records its pid, then waits on it.
    private func fixture(_ body: String) throws -> (script: URL, pidFile: URL, dir: URL) {
        let dir = try scratchDir()
        let script = dir.appendingPathComponent("fake-noodle")
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        try "#!/bin/sh\n\(body.replacingOccurrences(of: "PIDFILE", with: pidFile.path))\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, pidFile, dir)
    }

    private func grandchild(_ pidFile: URL) async -> pid_t? {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<60 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func timeoutKillsGrandchildToo() async throws {
        let f = try fixture("sleep 60 &\necho $! > PIDFILE\nwait")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let started = Date()
        // Execute through sh so concurrent fixture creation cannot cause ETXTBSY.
        let result = await CLI.run(executable: URL(fileURLWithPath: "/bin/sh"), [f.script.path], timeout: 1.5)
        #expect(result.code == 124)
        #expect(Date().timeIntervalSince(started) < 20)
        let pid = try #require(await grandchild(f.pidFile))
        defer { kill(pid, SIGKILL) }
        #expect(await gone(pid), "grandchild \(pid) survived the timeout; only the immediate process was killed")
    }

    @Test func cancelKillsGrandchildToo() async throws {
        let f = try fixture("sleep 60 &\necho $! > PIDFILE\nwait")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let task = Task { await CLI.run(executable: URL(fileURLWithPath: "/bin/sh"), [f.script.path], timeout: 120) }
        let pid = try #require(await grandchild(f.pidFile))
        defer { kill(pid, SIGKILL) }
        task.cancel()
        let result = await task.value
        #expect(result.code == 130)
        #expect(await gone(pid), "grandchild \(pid) survived the cancel")
    }

    @Test func exitCodesAndOutputSurviveTheSpawnPath() async throws {
        let f = try fixture("echo out; echo err >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // Through sh: another test's fork can briefly hold a new script open for writing, which makes exec fail with ETXTBSY.
        let result = await CLI.run(executable: URL(fileURLWithPath: "/bin/sh"), [f.script.path], timeout: 20)
        #expect(result.code == 3)
        #expect(result.output.contains("out") && result.output.contains("err"))
        let killed = try fixture("kill -KILL $$")
        defer { try? FileManager.default.removeItem(at: killed.dir) }
        let signalled = await CLI.run(executable: URL(fileURLWithPath: "/bin/sh"), [killed.script.path], timeout: 20)
        #expect(signalled.code == 128 + SIGKILL, "got \(signalled.code): \(signalled.output)")
    }
}
