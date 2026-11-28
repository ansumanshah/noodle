import Foundation
import Testing
@testable import NoodleCore

@Suite struct SetupCommandTests {
    @Test func importContextIsOneLiteralShellArgument() throws {
        for context in ["desktop-linux", "has space", "x'; echo injected; #", "$(echo injected)", "`echo injected`", "a\nb"] {
            let command = SetupPlan.importCommand(source: context)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "noodle() { printf '%s\\0' \"$@\"; }; " + command]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(data == Data(("import\0" + context + "\0--all\0").utf8))
        }
    }

    @Test func bashWriterUsesFirstExistingLoginFile() {
        #expect(SetupPlan.profileName(shell: "/bin/bash", existing: [".profile"]) == ".profile")
        #expect(SetupPlan.profileName(shell: "/bin/bash", existing: [".profile", ".bash_login"]) == ".bash_login")
        #expect(SetupPlan.profileName(shell: "/bin/bash", existing: [".profile", ".bash_login", ".bash_profile"]) == ".bash_profile")
        #expect(SetupPlan.profileName(shell: "/bin/bash", existing: [".bashrc"]) == ".bash_profile")
    }
}
