import Foundation
import Testing
@testable import NoodleCore

@Suite(.tags(.slow)) struct ToolDownloadProcessTests {
    @Test func preservesNonzeroExit() throws {
        let result = try ToolDownloadProcess().run(executable: "/bin/sh", arguments: ["-c", "exit 37"])
        #expect(result.code == 37 && result.cancelledSignal == nil)
    }

    @Test(arguments: [SIGINT, SIGTERM]) func cancellationReapsDownload(signal: Int32) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-tool-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let child = ToolDownloadProcess()
        let task = Task.detached {
            try child.run(executable: "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", ready.path])
        }
        defer { child.cancel(SIGKILL) }
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        child.cancel(signal)
        let result = try await task.value
        #expect(result.cancelledSignal == signal && result.code == 128 + signal)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
