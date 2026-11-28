import Foundation
import Testing
@testable import NoodleApp

@MainActor struct SetupUninstallTests {
    @Test func keepsDataByDefaultAndRequiresBothDeletionFlags() async throws {
        let directory = try scratchDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("noodle")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let flow = UninstallFlow { args in await CLI.run(executable: cli, args, timeout: 5) }
        #expect(!flow.deleteData)
        await flow.uninstall()
        #expect(flow.succeeded && flow.result?.output == "uninstall\n")
        let deleting = UninstallFlow { args in await CLI.run(executable: cli, args, timeout: 5) }
        deleting.deleteData = true
        await deleting.uninstall()
        #expect(deleting.succeeded && deleting.result?.output == "uninstall\n--delete-data\n--yes\n")
    }

    @Test func failurePreservesResultAndAllowsRetry() async {
        let flow = UninstallFlow { _ in .init(code: 7, output: "Could not remove LaunchAgent") }
        await flow.uninstall()
        #expect(!flow.succeeded && !flow.running)
        #expect(flow.result?.code == 7 && flow.result?.output == "Could not remove LaunchAgent")
        await flow.uninstall()
        #expect(flow.result?.code == 7)
    }

    @Test func restoresOnlyTheRecordedExistingContextWhenNoodleIsSelected() {
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "desktop-linux", available: ["desktop-linux"], owned: true) == "desktop-linux")
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "default", available: [], owned: true) == "default")
        #expect(UninstallNoodle.restoreContext(current: "orbstack", previous: "desktop-linux", available: ["desktop-linux"], owned: true) == nil)
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "deleted-context", available: [], owned: true) == nil)
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: nil, available: [], owned: true) == nil)
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "noodle", available: ["noodle"], owned: true) == nil)
        #expect(UninstallNoodle.restoreContext(current: "noodle", previous: "--help", available: ["--help"], owned: true) == nil)
    }
}
