import Darwin
import Foundation
import Testing
@testable import NoodleApp

@Suite struct SetupImportInvocationTests {
    private struct Fixture {
        let directory: URL
        var executable: URL { directory.appendingPathComponent("noodle") }
        var ready: URL { directory.appendingPathComponent("ready") }
        var cleaned: URL { directory.appendingPathComponent("cleaned") }
    }

    private func fixture(_ body: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture(directory: directory)
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\ncd \(quoted) || exit 1\n\(body)\n".write(to: fixture.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        return fixture
    }

    private func ready(_ fixture: Fixture) async throws -> pid_t {
        for _ in 0..<300 {
            if let value = try? String(contentsOf: fixture.ready, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    // Sending SIGKILL first, or returning before the trap finishes, loses the cleanup marker.
    @Test func cancellationWaitsForTermCleanup() async throws {
        let fixture = try fixture("""
        trap 'sleep 0.15; echo cleaned > cleaned; echo cleanup-finished; exit 0' TERM
        printf '%s\\n' "$@"
        echo $$ > ready
        while :; do sleep 0.02; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task { await SetupImportInvocation.run("desktop-linux", executable: fixture.executable, timeout: 10, cleanupGrace: 2) }
        defer { task.cancel() }
        let pid = try await ready(fixture)
        task.cancel()
        let result = await task.value
        #expect(result.code == 130)
        #expect(FileManager.default.fileExists(atPath: fixture.cleaned.path))
        #expect(result.output.contains("cleanup-finished"))
        #expect(result.output.contains("import\ndesktop-linux\n--all\n"))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    // A TERM-ignoring importer must be killed after the grace, and reaped before return.
    @Test(arguments: [false, true]) func stubbornImporterHasBoundedGrace(timeout: Bool) async throws {
        // The watchdog bounds a regression and leaves a marker when it had to step in.
        let fixture = try fixture("trap '' TERM\n(sleep 20; touch watchdog; kill -KILL $$) >/dev/null 2>&1 &\necho $$ > ready\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task { await SetupImportInvocation.run("source", executable: fixture.executable, timeout: timeout ? 3 : 10, cleanupGrace: 0.2) }
        defer { task.cancel() }
        let pid = try await ready(fixture)
        let start = ContinuousClock.now
        if !timeout { task.cancel() }
        let result = await task.value
        let elapsed = ContinuousClock.now - start
        #expect(result.code == (timeout ? 124 : 130))
        #expect(elapsed >= .milliseconds(150), "the grace was skipped")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("watchdog").path),
                "the runner waited for the watchdog instead of its own grace")
        #expect(result.output.contains("forcibly stopped"))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    // Cancellation present before invocation must never launch the executable.
    @Test func earlyCancellationDoesNotSpawn() async throws {
        let fixture = try fixture("echo $$ > ready")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SetupImportInvocation.run("source", executable: fixture.executable, timeout: 1, cleanupGrace: 0.1)
        }.value
        #expect(result.code == 130)
        #expect(!FileManager.default.fileExists(atPath: fixture.ready.path))
    }

    // Timeout uses the same graceful path, rather than bypassing the TERM handler.
    @Test func timeoutWaitsForTermCleanup() async throws {
        let fixture = try fixture("""
        trap 'sleep 0.15; echo cleaned > cleaned; echo cleanup-finished; exit 0' TERM
        echo $$ > ready
        while :; do sleep 0.02; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = await SetupImportInvocation.run("source", executable: fixture.executable, timeout: 3, cleanupGrace: 2)
        #expect(result.code == 124)
        #expect(FileManager.default.fileExists(atPath: fixture.cleaned.path))
        #expect(result.output.contains("cleanup-finished"))
        let pid = try await ready(fixture)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func preservesFailureAndBothOutputStreams() async throws {
        let fixture = try fixture("echo stdout; echo stderr >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = await SetupImportInvocation.run("source", executable: fixture.executable, timeout: 1)
        #expect(result.code == 7)
        #expect(result.output.contains("stdout") && result.output.contains("stderr"))
    }

    @Test func selectedKindsReachTheImporter() async throws {
        let fixture = try fixture("printf '%s\\n' \"$@\"")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = await SetupImportInvocation.run("orbstack", flags: ["--volumes"], executable: fixture.executable, timeout: 1)
        #expect(result.code == 0)
        #expect(result.output == "import\norbstack\n--volumes\n")
    }
}
